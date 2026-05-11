/*-------------------------------------------------------------------------
 *
 * pg_stat_backtrace.c
 *		Get / log C-level backtrace of any PostgreSQL process via
 *		ptrace(2) + libunwind.
 *
 * The extension exposes two SQL-callable functions:
 *
 *   pg_get_backtrace(pid)   -- returns the backtrace as text
 *   pg_log_backtrace(pid)   -- writes the backtrace to the server log
 *
 * Both share the same capture path: PTRACE_SEIZE the target (which does
 * NOT stop it), send PTRACE_INTERRUPT to briefly halt it, unwind its
 * stack with libunwind (via the libunwind-ptrace UPT accessors), then
 * PTRACE_DETACH.  The target is paused for typically single-digit
 * milliseconds.
 *
 * Rationale for SEIZE/INTERRUPT instead of the classic ATTACH + SIGSTOP
 * approach:
 *   - SEIZE does not inject any signal into the target, so we do not
 *     risk a SIGSTOP being left pending if our own tracer process
 *     crashes mid-capture.  With ATTACH, a crashing tracer would cause
 *     the kernel to auto-detach *and inject* the pending SIGSTOP,
 *     leaving the target in T-state and hanging the PG instance until
 *     a manual SIGCONT.  With SEIZE the kernel auto-detach is clean.
 *   - INTERRUPT reports its stop as PTRACE_EVENT_STOP, which is
 *     unambiguously distinguishable from a signal-delivery-stop
 *     racing with attach.  We still reinject any concurrently
 *     delivered signals (SIGUSR1 from procsignal, SIGTERM from
 *     shutdown, ...) via PTRACE_CONT, but the state machine is much
 *     simpler than with ATTACH.
 *   - Requires Linux 3.4 (March 2012), which predates every kernel
 *     shipped with a PostgreSQL major this extension targets.
 *
 * Permission model (enforced inside this file -- the SQL wrapper
 * REVOKEs EXECUTE from PUBLIC by default, but a site administrator
 * may GRANT it to a monitoring role):
 *
 *   superuser       : may target any PG process in this instance,
 *                     including auxiliary processes (walwriter,
 *                     checkpointer, walsender, autovacuum, ...).
 *   non-superuser   : may target only a regular backend that runs
 *                     under a role they have membership in.  Mirrors
 *                     the policy of the in-core pg_signal_backend()
 *                     helper.  Auxiliary processes have no role and
 *                     are always rejected for non-superusers.
 *
 * Safety checks:
 *   - Self (pid == MyProcPid) is rejected; a process cannot ptrace
 *     itself on Linux.
 *   - Postmaster is rejected; pausing it would block fork() of
 *     new connections.
 *   - The target's real UID is re-verified after PTRACE_SEIZE to
 *     close the narrow PID-reuse race window between
 *     BackendPidGetProc() and ptrace().
 *
 * Output format mimics pstack(1):
 *
 *     #N  0x<ip>  <symbol>+0x<off>
 *
 * The symbolizer is libunwind's unw_get_proc_name(), which walks the
 * target binary's ELF symbol tables internally.  We do not require
 * frame-pointers in the target -- libunwind unwinds via DWARF CFI
 * (.eh_frame), so any architecture libunwind supports works:
 * x86_64, aarch64, ppc64le, riscv64, loongarch64, s390x, i386,
 * arm, mips, ...
 *
 * Linux only.  ptrace semantics are Linux-specific and we read
 * /proc/<pid>/status for UID re-verification.
 *
 *
 * Portions Copyright (c) 2024-2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *		contrib/pg_stat_backtrace/pg_stat_backtrace.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#if !defined(__linux__)
#error "pg_stat_backtrace requires Linux (uses Linux ptrace + /proc)"
#endif

#include <sys/ptrace.h>
#include <sys/wait.h>

/*
 * This file uses WIFSTOPPED / WIFEXITED / WIFSIGNALED / WSTOPSIG
 * macros, which are in <sys/wait.h>, so we don't need an explicit
 * <signal.h> include.  If a future change here adds a kill(2) call
 * or directly references SIGxxx constants, adding <signal.h> is
 * safe and does not conflict with PG headers on Linux -- PG only
 * overrides signal symbols on WIN32, which we exclude via the
 * __linux__ guard above.
 */

#define UNW_REMOTE_ONLY
#include <libunwind.h>
#include <libunwind-ptrace.h>

/*
 * PTRACE_SEIZE / PTRACE_INTERRUPT / PTRACE_EVENT_STOP were added in
 * Linux 3.4 (March 2012).  Every kernel shipped with a distro that
 * runs a supported PostgreSQL major has them, but glibc on some
 * older build hosts lacks the constant definitions.  Provide the
 * raw numeric values from the kernel UAPI as a fallback so the
 * extension still builds against ancient userspace headers.
 */
#ifndef PTRACE_SEIZE
#define PTRACE_SEIZE		0x4206
#endif
#ifndef PTRACE_INTERRUPT
#define PTRACE_INTERRUPT	0x4207
#endif
#ifndef PTRACE_EVENT_STOP
#define PTRACE_EVENT_STOP	128
#endif

/*
 * __WALL is a Linux-specific waitpid() flag that allows waiting on
 * tracees regardless of the parent/child relationship.  Not defined
 * in strict POSIX mode; fall back to 0 (plain waitpid), which works
 * for ptraced processes on all modern Linux kernels.
 */
#ifndef __WALL
#define __WALL 0
#endif

#include "fmgr.h"
#include "miscadmin.h"
#include "storage/lwlock.h"
#include "storage/proc.h"
#include "storage/procarray.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/elog.h"
#include "utils/timestamp.h"

/*
 * PG_MODULE_MAGIC_EXT was introduced in PG18 and is the form preferred
 * by all in-tree contribs starting with that release; fall back to the
 * classic PG_MODULE_MAGIC on PG14-17 so this file still builds against
 * older majors with the same source.
 */
#ifdef PG_MODULE_MAGIC_EXT
PG_MODULE_MAGIC_EXT(
					.name = "pg_stat_backtrace",
					.version = PG_VERSION
);
#else
PG_MODULE_MAGIC;
#endif

PG_FUNCTION_INFO_V1(pg_get_backtrace);
PG_FUNCTION_INFO_V1(pg_log_backtrace);


/*
 * Tunables.  These are intentionally not GUCs: they are deep
 * implementation details, not knobs operators should tweak per call.
 * Grouped here so that any future re-tuning (or promotion to GUCs)
 * only touches one place.
 */

/* ---- Unwind shape -------------------------------------------------- */

/* Cap unwind depth.  Anything deeper is almost certainly runaway
 * recursion in the target. */
#define PSBT_MAX_FRAMES					256

/* Cap on a single libunwind symbol-name length.  Truncated names are
 * still useful, but we don't want pathological allocations on
 * corrupted symbol tables. */
#define PSBT_SYMBOL_MAX					512

/* ---- Attach path (psbt_attach_and_capture) ------------------------- */

/* Bound how long we'll wait for the target to actually enter the
 * interrupt-induced stop.  PTRACE_INTERRUPT is asynchronous; the
 * tracee may not yet have reached a stoppable point when the
 * syscall returns. */
#define PSBT_ATTACH_WAIT_SECS			3

/* Exponential-backoff envelope for the attach wait poll loop.
 * Starts tight to keep the typical capture fast and backs off to
 * avoid burning CPU when the tracee is slow to reach a stop point. */
#define PSBT_ATTACH_POLL_START_US		100L	/* 0.1 ms */
#define PSBT_ATTACH_POLL_MAX_US			10000L	/* 10   ms */

/* ---- Detach cleanup path (psbt_ptrace_detach_silent) --------------- */

/* Drain loop budget when the tracee is not yet in ptrace-stop.
 * Iteration-count bound, not wall-clock: unaffected by pg_usleep
 * EINTR.  At PSBT_DETACH_DRAIN_SLEEP_US below this gives roughly
 * PSBT_DETACH_DRAIN_MAX_ITERS * 1 ms = 100 ms worst case. */
#define PSBT_DETACH_DRAIN_MAX_ITERS		100
#define PSBT_DETACH_DRAIN_SLEEP_US		1000L	/* 1 ms */

/* ---- /proc<pid>/status scanner (psbt_verify_target_uid) ----------- */

/*
 * Path buffer for "/proc/<pid>/status".  The minimal required size is
 * strlen("/proc/") + 10 (INT32 decimal) + strlen("/status") + 1 = 24
 * bytes; we round generously up to 64 to leave headroom for possible
 * future siblings (e.g. /proc/<pid>/comm) without churning callers.
 */
#define PSBT_PROC_PATH_LEN				64

/* Line buffer for /proc/<pid>/status.  The "Uid:" line and every
 * preceding line (Name/State/Tgid/Pid/PPid/TracerPid) fits easily;
 * we only need enough to survive a hypothetical future kernel that
 * widens some field.  See the scanner's comment for why over-long
 * lines are harmless. */
#define PSBT_PROC_LINE_LEN				256


/* ------------------------------------------------------------------ */
/* permission and target validation                                    */
/* ------------------------------------------------------------------ */

/*
 * Per-target attributes captured atomically (under ProcArrayLock for
 * regular backends).  We snapshot rather than carry around a PGPROC*
 * because the underlying slot may be reassigned to an unrelated
 * backend after we drop the lock; any later read of proc->roleId
 * could then return the *new* occupant's role and grant unintended
 * access (see also the post-attach UID re-verification below, which
 * closes the wider race against PID re-use by an OS-level attacker).
 */
typedef struct PsbtTargetInfo
{
	bool		found;			/* false if pid is not a PG process */
	bool		is_auxproc;		/* true if pid is an auxiliary process */
	Oid			role_id;		/* InvalidOid for aux procs and not-yet-
								 * authenticated backends */
}			PsbtTargetInfo;

/*
 * Resolve `pid` to a PG process owned by this instance and snapshot
 * the few fields the permission check needs, all under ProcArrayLock
 * so the snapshot is internally consistent.
 *
 * Returns info.found = false when the pid does not belong to this
 * instance; the caller should then WARNING+return-NULL rather than
 * raising.
 */
static PsbtTargetInfo
psbt_resolve_target(int pid)
{
	PsbtTargetInfo info = {0};
	PGPROC	   *proc;

	/*
	 * Take ProcArrayLock SHARED ourselves so we can both look up the
	 * regular-backend slot AND copy roleId out atomically.  Using
	 * BackendPidGetProc() (which acquires + releases the lock
	 * internally) is unsafe here: by the time we read proc->roleId
	 * the slot might have been reassigned to a different backend.
	 */
	LWLockAcquire(ProcArrayLock, LW_SHARED);

	proc = BackendPidGetProcWithLock(pid);
	if (proc != NULL)
	{
		info.found = true;
		info.is_auxproc = false;
		info.role_id = proc->roleId;
		LWLockRelease(ProcArrayLock);
		return info;
	}

	LWLockRelease(ProcArrayLock);

	/*
	 * Auxiliary processes are not in ProcArray; AuxiliaryPidGetProc
	 * does its own (different) locking internally.  Aux procs have
	 * no role attached, so there is nothing to snapshot atomically.
	 */
	proc = AuxiliaryPidGetProc(pid);
	if (proc != NULL)
	{
		info.found = true;
		info.is_auxproc = true;
		info.role_id = InvalidOid;
		return info;
	}

	return info;
}

/*
 * Enforce the permission model:
 *
 *   superuser       : allowed to target anything.
 *   non-superuser   : allowed to target a regular backend they have
 *                     role-membership of (and that backend must NOT
 *                     itself be a superuser session, mirroring
 *                     pg_signal_backend's policy).  Auxiliary
 *                     processes have no role and are rejected.
 *
 * Self (pid == MyProcPid) is always allowed by role policy (you can
 * always introspect yourself), but ptrace can't attach to self;
 * that is enforced separately by the caller before this function
 * runs.
 */
static void
psbt_check_permission(const PsbtTargetInfo *info)
{
	if (superuser())
		return;					/* superuser: no further checks */

	if (info->is_auxproc)
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("permission denied to target auxiliary process"),
				 errdetail("Only superusers may target auxiliary processes.")));

	/*
	 * roleId == InvalidOid means the target hasn't finished
	 * InitPostgres yet (still in startup packet processing).  Don't
	 * leak this transient state to non-superusers.
	 */
	if (!OidIsValid(info->role_id))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("permission denied to target backend"),
				 errdetail("Target backend has not finished authenticating.")));

	/*
	 * Mirror pg_signal_backend(): even with role membership, a
	 * non-superuser is not allowed to target a superuser session.
	 */
	if (superuser_arg(info->role_id))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("permission denied to target backend"),
				 errdetail("Only superusers may target a backend owned by a superuser.")));

	if (!has_privs_of_role(GetUserId(), info->role_id))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("permission denied to target backend"),
				 errdetail("You must be a member of the role that owns "
						   "the target backend.")));
}


/* ------------------------------------------------------------------ */
/* ptrace + libunwind capture                                          */
/* ------------------------------------------------------------------ */

/*
 * PTRACE_DETACH a SEIZE-attached tracee.
 *
 * Preconditions when we reach this function:
 *   a) The tracee is currently in a ptrace-stop -- either the
 *      PTRACE_EVENT_STOP we got from PTRACE_INTERRUPT, or a
 *      signal-delivery-stop we failed to drain and are abandoning.
 *   b) We are the sole tracer.
 *
 * PTRACE_DETACH is a "restarting" command; per ptrace(2) it requires
 * the tracee to be in ptrace-stop and returns ESRCH otherwise.  If
 * somehow our assumption (a) is wrong (paranoid cleanup after a
 * soft failure) we take one shot at PTRACE_INTERRUPT to force a
 * stop, drain pending stops, then retry detach.  Unlike the classic
 * ATTACH + kill(SIGSTOP) approach, PTRACE_INTERRUPT does NOT inject
 * any signal into the tracee, so a concurrent tracer-crash here
 * never leaves the tracee with a stuck SIGSTOP.
 *
 * All errors are intentionally ignored: this is the cleanup path and
 * the caller has already decided the outcome.  In the unlikely worst
 * case the kernel will auto-detach cleanly when our backend exits.
 */
static void
psbt_ptrace_detach_silent(pid_t pid)
{
	int			save_errno = errno;
	int			rc;
	int			i;

	/* Fast path: tracee is already in ptrace-stop (the common case). */
	rc = ptrace(PTRACE_DETACH, pid, (void *) 0, (void *) 0);
	if (rc == 0)
	{
		errno = save_errno;
		return;
	}

	/*
	 * Fast path failed.  Distinguish "tracee died" from "tracee is
	 * running" by asking the kernel to interrupt it; PTRACE_INTERRUPT
	 * returns 0 for live tracees and -1/ESRCH for dead ones.
	 */
	if (ptrace(PTRACE_INTERRUPT, pid, (void *) 0, (void *) 0) < 0)
	{
		/* Tracee gone; kernel already cleaned up. */
		errno = save_errno;
		return;
	}

	/*
	 * Drain pending ptrace-stops, reinjecting any non-stop signals,
	 * until we see the PTRACE_EVENT_STOP (or signal-delivery-stop
	 * for SIGSTOP) that will let us detach cleanly.
	 */
	for (i = 0; i < PSBT_DETACH_DRAIN_MAX_ITERS; i++)
	{
		int			status;
		pid_t		w = waitpid(pid, &status, WNOHANG | __WALL);

		if (w == pid)
		{
			if (WIFEXITED(status) || WIFSIGNALED(status))
			{
				/* Tracee died.  Kernel auto-detaches; we're done. */
				errno = save_errno;
				return;
			}
			if (WIFSTOPPED(status))
			{
				/*
				 * Group-stop / INTERRUPT-induced stop arrives as
				 * status>>16 == PTRACE_EVENT_STOP.  A plain
				 * signal-delivery-stop has status>>16 == 0 and
				 * WSTOPSIG() gives the signal.
				 */
				if ((status >> 16) == PTRACE_EVENT_STOP)
					break;		/* ready to detach */

				/*
				 * Some other signal got delivered first.  Re-inject
				 * it so the tracee's handler runs, then keep waiting
				 * for the interrupt-induced stop.
				 */
				(void) ptrace(PTRACE_CONT, pid, (void *) 0,
							  (void *) (intptr_t) WSTOPSIG(status));
				continue;
			}
			/* WIFCONTINUED or similar -- keep polling. */
		}
		else if (w < 0 && errno != EINTR && errno != ECHILD)
		{
			/* Unexpected waitpid failure; stop retrying. */
			break;
		}

		pg_usleep(PSBT_DETACH_DRAIN_SLEEP_US);

		/*
		 * EINTR from pg_usleep() (caused by an unrelated signal
		 * delivered to *our* backend) only makes the next iteration
		 * poll sooner; the loop bound PSBT_DETACH_DRAIN_MAX_ITERS is
		 * iteration-count based, not wall-clock based, so the worst
		 * case is that we reach the last-ditch detach a few ms
		 * earlier.  We do NOT call CHECK_FOR_INTERRUPTS() in this
		 * cleanup path: an errthrow here would abandon the tracee
		 * in T-state until our process exits, which is strictly
		 * worse than spending up to ~100 ms finishing the detach.
		 */
	}

	/*
	 * Last-ditch detach.  If we never saw PTRACE_EVENT_STOP (deadline
	 * reached) we still try; at worst we get ESRCH and the kernel
	 * handles cleanup on our next exit.
	 *
	 * Before detaching, do one non-blocking probe: if the tracee is
	 * currently in a signal-delivery-stop we have not yet absorbed,
	 * a plain PTRACE_DETACH(data=0) would silently discard that
	 * signal (e.g. a SIGUSR1 queued by procsignal, a SIGTERM from
	 * shutdown).  Instead, detach with data=<sig>, which injects
	 * the pending signal as part of the restart -- the canonical
	 * "detach-with-signal" sequence from ptrace(2).  Losing the
	 * signal is a real correctness bug even in this cleanup path.
	 */
	{
		int			status;
		pid_t		w = waitpid(pid, &status, WNOHANG | __WALL);

		if (w == pid && WIFSTOPPED(status) &&
			(status >> 16) != PTRACE_EVENT_STOP)
		{
			(void) ptrace(PTRACE_DETACH, pid, (void *) 0,
						  (void *) (intptr_t) WSTOPSIG(status));
			errno = save_errno;
			return;
		}
		/* Otherwise fall through to the plain detach below. */
	}

	/* data=0: no signal injection regardless of stop state. */
	(void) ptrace(PTRACE_DETACH, pid, (void *) 0, (void *) 0);

	errno = save_errno;
}

/*
 * Re-verify (after PTRACE_SEIZE) that the still-attached `pid` is
 * owned by the same UID as us.  Defends against the very narrow race
 * where the PG process we resolved via BackendPidGetProc() exits
 * between resolution and ptrace attach and the kernel hands the PID
 * to an unrelated process owned by another user.
 *
 * Conservatively returns false when the status file cannot be read
 * or when the Uid: line cannot be located -- both are treated as
 * "target does not provably belong to us".
 *
 * errno is saved and restored so callers (which only examine our
 * return value, not %m) see an unchanged errno across the call.
 */
static bool
psbt_verify_target_uid(pid_t pid)
{
	char		path[PSBT_PROC_PATH_LEN];
	FILE	   *fp;
	char		line[PSBT_PROC_LINE_LEN];
	uid_t		my_uid;
	bool		matched = false;
	int			save_errno = errno;

	my_uid = geteuid();

	snprintf(path, sizeof(path), "/proc/%d/status", (int) pid);
	fp = fopen(path, "r");
	if (fp == NULL)
	{
		errno = save_errno;
		return false;
	}

	/*
	 * Scan lines looking for "Uid:".  Every Linux kernel emits Uid:
	 * within the first few dozen bytes of /proc/<pid>/status, well
	 * inside our PSBT_PROC_LINE_LEN-byte line buffer, and every
	 * preceding line is also short (Name: is capped at
	 * TASK_COMM_LEN=16, State/Pid/Tgid/PPid/TracerPid are all tiny).
	 * A pathological future kernel that injected a multi-kilobyte
	 * line before Uid: would cause fgets() to return the first
	 * (PSBT_PROC_LINE_LEN - 1) bytes of that line, not "Uid:", so
	 * we'd simply skip it and continue reading; we never process
	 * a false Uid: match from a truncated tail.
	 */
	while (fgets(line, sizeof(line), fp) != NULL)
	{
		unsigned int real_uid;

		/*
		 * The "Uid:" line is "Uid:\t<real>\t<eff>\t<saved>\t<fs>"
		 * on standard kernels.  Some minimal/embedded kernels use
		 * spaces instead of tabs; sscanf "%u" with a leading space
		 * tolerates both.
		 */
		if (strncmp(line, "Uid:", 4) == 0 &&
			sscanf(line + 4, " %u", &real_uid) == 1)
		{
			matched = ((uid_t) real_uid == my_uid);
			break;
		}
	}

	/*
	 * If fgets() returned NULL we could be at EOF (normal) or have
	 * hit a read error (e.g. the target exited while we were reading
	 * its /proc entry).  Either way we've either made a decision
	 * above or we're giving up -- treating the silent "no Uid: line
	 * found" case as untrusted is the safe default.  We still query
	 * ferror() so the glibc _FORTIFY_SOURCE=2 warn_unused_result
	 * attribute is satisfied, but the result is intentionally not
	 * used: a read error yields matched==false which is already the
	 * conservative default on any parse failure.
	 */
	if (ferror(fp))
	{
		/* read error -> treat as untrusted; nothing else to do */
	}
	fclose(fp);

	errno = save_errno;
	return matched;
}

/*
 * Capture the backtrace of an already-attached, already-stopped
 * tracee using libunwind.  Returns a palloc'd, NUL-terminated string
 * in the current memory context.
 *
 * Algorithm:
 *   1. Allocate a libunwind "remote" address space and a UPT info
 *      handle bound to `pid`.  Together they teach libunwind how to
 *      read the tracee's registers and memory through ptrace.
 *   2. unw_init_remote() seeds the cursor from the tracee's current
 *      register state.
 *   3. Loop unw_step() until end-of-stack or PSBT_MAX_FRAMES,
 *      formatting one frame per iteration.
 *   4. Symbolize each IP via unw_get_proc_name(), which walks the
 *      target binary's ELF symbol tables internally.
 *
 * libunwind handles all architecture-specific work (register
 * decoding, DWARF CFI evaluation, frame layout) transparently, so
 * this function works on every architecture libunwind has been
 * built for.  We do NOT require -fno-omit-frame-pointer in the
 * target.
 */
static char *
psbt_capture(pid_t pid)
{
	StringInfoData buf;
	/*
	 * `as` and `upt` are read in PG_CATCH below, so they must be
	 * volatile-qualified to keep their values across siglongjmp(3)
	 * (POSIX 7.1.2 / C11 7.13.2.1).  Without volatile, the compiler
	 * is allowed to keep them only in registers, and the values
	 * observed inside PG_CATCH would be indeterminate.
	 */
	unw_addr_space_t volatile as = NULL;
	void	   *volatile upt = NULL;
	unw_cursor_t cursor;
	/*
	 * `frame` is read after the PG_TRY / PG_END_TRY block via the loop
	 * that populates it.  GCC's -Wclobbered conservatively warns about
	 * non-volatile locals live across sigsetjmp().  Marking it volatile
	 * both silences the warning and matches the POSIX requirement for
	 * any local that is modified between setjmp() and longjmp() and is
	 * still read after longjmp returns.
	 */
	volatile int frame = 0;
	int			rc;

	as = unw_create_addr_space(&_UPT_accessors, 0);
	if (as == NULL)
	{
		/* Build the diagnostic *after* we know there's nothing to free. */
		initStringInfo(&buf);
		appendStringInfoString(&buf, "pstack: unw_create_addr_space failed");
		return buf.data;
	}

	/* Per-thread cache: avoids re-parsing .eh_frame on every frame.
	 * Essentially required for usable performance on deep stacks. */
	unw_set_caching_policy((unw_addr_space_t) as, UNW_CACHE_PER_THREAD);

	upt = _UPT_create(pid);
	if (upt == NULL)
	{
		unw_destroy_addr_space((unw_addr_space_t) as);
		initStringInfo(&buf);
		appendStringInfoString(&buf, "pstack: _UPT_create failed");
		return buf.data;
	}

	/* From here onward `as` and `upt` are owned by us; PG_TRY ensures
	 * they get destroyed on every exit path including ereport(ERROR). */
	initStringInfo(&buf);

	PG_TRY();
	{
		rc = unw_init_remote(&cursor, (unw_addr_space_t) as, (void *) upt);
		if (rc < 0)
		{
			appendStringInfo(&buf,
							 "pstack: unw_init_remote failed (%d)", rc);
		}
		else
		{
			do
			{
				unw_word_t	ip = 0;
				unw_word_t	off = 0;
				char		sym[PSBT_SYMBOL_MAX];
				int			gpn_rc;

				if (unw_get_reg(&cursor, UNW_REG_IP, &ip) < 0)
					break;

				/*
				 * unw_get_proc_name returns 0 on success, or a
				 * negative error.  UNW_ENOMEM means truncation,
				 * which is fine -- we still emit what we got.  Any
				 * other error means we can't symbolize at all; emit
				 * "??".
				 */
				sym[0] = '\0';
				gpn_rc = unw_get_proc_name(&cursor, sym, sizeof(sym), &off);
				if (gpn_rc != 0 && gpn_rc != -UNW_ENOMEM)
				{
					strlcpy(sym, "??", sizeof(sym));
					off = 0;
				}

				if (buf.len > 0)
					appendStringInfoChar(&buf, '\n');
				/*
				 * Frame-index column is %-3d so that frames stay
				 * aligned up to PSBT_MAX_FRAMES = 256 (3 digits).
				 * If PSBT_MAX_FRAMES is ever bumped past 999 the
				 * width here should be adjusted accordingly.
				 */
				appendStringInfo(&buf,
								 "#%-3d 0x%016" PRIx64 " in %s+0x%" PRIx64,
								 frame, (uint64) ip,
								 sym[0] != '\0' ? sym : "??",
								 (uint64) off);

				frame++;
				if (frame >= PSBT_MAX_FRAMES)
				{
					appendStringInfoString(&buf,
										   "\npstack: frame limit reached, output truncated");
					break;
				}

				CHECK_FOR_INTERRUPTS();
			} while ((rc = unw_step(&cursor)) > 0);

			if (rc < 0)
				appendStringInfo(&buf,
								 "\npstack: unw_step failed at frame %d (%d)",
								 frame, rc);
		}
	}
	PG_CATCH();
	{
		_UPT_destroy((void *) upt);
		unw_destroy_addr_space((unw_addr_space_t) as);
		PG_RE_THROW();
	}
	PG_END_TRY();

	_UPT_destroy((void *) upt);
	unw_destroy_addr_space((unw_addr_space_t) as);

	if (buf.len == 0)
		appendStringInfoString(&buf, "pstack: no frames captured");

	return buf.data;
}

/*
 * PTRACE_SEIZE -> PTRACE_INTERRUPT -> wait-for-stop -> psbt_capture
 * -> PTRACE_DETACH.
 *
 * Unlike the classic PTRACE_ATTACH, PTRACE_SEIZE does not stop the
 * tracee and does not inject any signal into it.  We then use
 * PTRACE_INTERRUPT to trigger a PTRACE_EVENT_STOP, which is a pure
 * ptrace-internal stop -- no SIGSTOP is ever delivered to the target.
 *
 * This matters for safety: if our backend dies (OOM, FATAL, segfault)
 * mid-capture, the kernel auto-detaches cleanly.  With PTRACE_ATTACH
 * the injected SIGSTOP would be propagated, leaving the target
 * permanently in T-state requiring a manual SIGCONT to recover.
 *
 * Uses PG_TRY so we ALWAYS detach, even if waiting or capture throws
 * (including via a query cancel CHECK_FOR_INTERRUPTS).  Forgetting to
 * detach would leave the target frozen and unowned, which is far
 * worse than failing the function call.
 */
static char *
psbt_attach_and_capture(pid_t pid)
{
	char	   *result = NULL;
	int			status;
	pid_t		waited;
	TimestampTz deadline;

	/*
	 * `attached` is read inside PG_CATCH below to decide whether we
	 * still owe the kernel a PTRACE_DETACH.  Because PG_CATCH is
	 * reached via siglongjmp(3), any local variable modified inside
	 * the corresponding PG_TRY must be volatile-qualified or its
	 * value after the longjmp is indeterminate (POSIX 7.1.2 / C11
	 * 7.13.2.1).
	 */
	volatile bool attached = false;

	/*
	 * PTRACE_SEIZE (Linux 3.4+) attaches without stopping the tracee
	 * and without sending any signal.  The `data` argument accepts a
	 * bitmask of PTRACE_O_* options, applied atomically with the
	 * attach; we don't need any options, so pass 0.
	 */
	if (ptrace(PTRACE_SEIZE, pid, (void *) 0, (void *) 0) < 0)
	{
		/*
		 * EPERM here typically means yama ptrace_scope blocked us
		 * (or we're trying to attach across UIDs).  ESRCH means the
		 * target died between the resolve and the attach.  Both are
		 * permission/state issues, not file-access issues, so use
		 * ERRCODE_INSUFFICIENT_PRIVILEGE.  errno is still set from
		 * the failing ptrace() call, so %m gives us the kernel
		 * description without an explicit strerror() call.
		 */
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("could not attach to PID %d via ptrace: %m",
						(int) pid),
				 errhint("Check that kernel.yama.ptrace_scope permits attach "
						 "and that the target runs as the same user.")));
	}
	attached = true;

	PG_TRY();
	{
		/*
		 * Kick the tracee into a ptrace-stop without sending any
		 * signal.  Per ptrace(2), PTRACE_INTERRUPT makes the tracee
		 * enter a stop reported as status>>16 == PTRACE_EVENT_STOP
		 * on the next waitpid().  If the tracee is already in a
		 * signal-delivery-stop for an unrelated signal, that stop
		 * is reported first; we reinject and keep polling.
		 */
		if (ptrace(PTRACE_INTERRUPT, pid, (void *) 0, (void *) 0) < 0)
		{
			/*
			 * Target died between SEIZE and INTERRUPT.  Not
			 * actionable; treat like "exited before capture".
			 */
			attached = false;
			ereport(ERROR,
					(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
					 errmsg("PID %d exited before backtrace could be captured",
							(int) pid)));
		}

		/*
		 * Wait (with a bounded deadline and exponential backoff) for
		 * the PTRACE_EVENT_STOP induced by our PTRACE_INTERRUPT.
		 *
		 * IMPORTANT: while we're waiting, the kernel may report
		 * *other* pending signals first (e.g. a SIGUSR1 sent
		 * concurrently by another PG backend via procsignal, or
		 * SIGTERM from a shutdown).  ptrace(2) explicitly warns
		 * about these races and the documented workaround is to
		 * PTRACE_CONT-reinject the unrelated signals and keep
		 * waiting until the stop we asked for shows up.  If we
		 * instead treated the first stop as "we're stopped, go
		 * ahead and detach", we would silently swallow that
		 * pending signal, potentially losing a sinval invalidation,
		 * a logical-rep apply request, or a graceful shutdown
		 * signal.
		 */
		deadline = TimestampTzPlusMilliseconds(GetCurrentTimestamp(),
											   PSBT_ATTACH_WAIT_SECS * 1000L);
		{
			long		sleep_us = PSBT_ATTACH_POLL_START_US;

			for (;;)
			{
				waited = waitpid(pid, &status, WNOHANG | __WALL);
				if (waited == pid)
				{
					if (WIFSTOPPED(status))
					{
						/*
						 * PTRACE_EVENT_STOP is the interrupt-induced
						 * stop we're after.  Any other WIFSTOPPED is
						 * a racing signal-delivery-stop; reinject
						 * and keep waiting.
						 *
						 * Reinjection note: if this is a fatal
						 * signal (SIGTERM, SIGQUIT, ...) the tracee
						 * will die shortly afterwards.  The next
						 * waitpid() will then report WIFEXITED /
						 * WIFSIGNALED and we fall through to the
						 * "target died" branch below.
						 *
						 * Ignoring the PTRACE_CONT return value:
						 * the only realistic failure mode here is
						 * ESRCH (tracee already dead), which the
						 * next waitpid() will also surface; any
						 * other error would be a kernel bug we
						 * cannot meaningfully recover from.
						 */
						if ((status >> 16) == PTRACE_EVENT_STOP)
							break;

						(void) ptrace(PTRACE_CONT, pid, (void *) 0,
									  (void *) (intptr_t) WSTOPSIG(status));
						continue;
					}

					/* WIFEXITED / WIFSIGNALED: target died. */
					attached = false;
					ereport(ERROR,
							(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
							 errmsg("PID %d exited before backtrace could be captured",
									(int) pid)));
				}
				if (waited < 0 && errno != EINTR && errno != ECHILD)
				{
					int			save_errno = errno;

					psbt_ptrace_detach_silent(pid);
					attached = false;
					errno = save_errno;
					ereport(ERROR,
							(errcode(ERRCODE_INTERNAL_ERROR),
							 errmsg("waitpid failed for PID %d: %m",
									(int) pid)));
				}
				if (GetCurrentTimestamp() > deadline)
				{
					psbt_ptrace_detach_silent(pid);
					attached = false;
					ereport(ERROR,
							(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
							 errmsg("timed out waiting for PID %d to stop after ptrace attach",
									(int) pid)));
				}

				/*
				 * pg_usleep() returns early (EINTR) if a signal is
				 * delivered to *our* backend -- procsignal SIGUSR1,
				 * SIGTERM, SIGINT, SIGHUP, SIGALRM, ...  That is not
				 * a problem and is in fact desirable: the next
				 * waitpid(WNOHANG) simply polls again (cheap), the
				 * deadline check below is wall-clock based so it is
				 * unaffected by a shortened sleep, and the trailing
				 * CHECK_FOR_INTERRUPTS() ensures SIGTERM / query
				 * cancel are acted upon promptly (on ERROR the
				 * PG_CATCH arm detaches the tracee cleanly).  Do NOT
				 * convert this to WaitLatch(): we do not own a latch
				 * lifecycle here and the current loop is already as
				 * responsive as a latch wait would be.
				 */
				pg_usleep(sleep_us);
				sleep_us *= 2;
				if (sleep_us > PSBT_ATTACH_POLL_MAX_US)
					sleep_us = PSBT_ATTACH_POLL_MAX_US;

				CHECK_FOR_INTERRUPTS();
			}
		}

		/*
		 * PID-reuse defense: now that the target is stopped,
		 * confirm its real UID still matches ours.  If not, the
		 * original PG process exited and the PID was recycled to
		 * something we shouldn't be inspecting.
		 */
		if (!psbt_verify_target_uid(pid))
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
					 errmsg("PID %d is not owned by the PostgreSQL server user",
							(int) pid),
					 errhint("The original target may have exited and "
							 "the PID been reused.")));

		result = psbt_capture(pid);
	}
	PG_CATCH();
	{
		if (attached)
			psbt_ptrace_detach_silent(pid);
		PG_RE_THROW();
	}
	PG_END_TRY();

	if (attached)
		psbt_ptrace_detach_silent(pid);
	return result;
}


/* ------------------------------------------------------------------ */
/* SQL entry points                                                    */
/* ------------------------------------------------------------------ */

/*
 * Common preflight shared by pg_get_backtrace and pg_log_backtrace.
 *
 * Validates the pid argument, refuses obviously unsafe targets
 * (self, postmaster), resolves the target PGPROC, and runs the
 * permission check.  Returns the captured backtrace as a palloc'd
 * cstring on success.
 *
 * Returns NULL only when `pid` is non-positive or not a PG process;
 * in that case a WARNING has already been emitted.  Other failures
 * are reported via ereport(ERROR).
 */
static char *
psbt_capture_for_pid(int pid)
{
	PsbtTargetInfo target;

	if (pid <= 0)
	{
		ereport(WARNING,
				(errmsg("invalid PID %d", pid)));
		return NULL;
	}

	if (pid == MyProcPid)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("cannot ptrace self via pg_stat_backtrace"),
				 errhint("A process cannot ptrace itself on Linux. "
						 "Run the function from a different session targeting your PID.")));

	if (pid == PostmasterPid)
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("cannot ptrace the postmaster process (PID %d)",
						(int) PostmasterPid),
				 errhint("Stopping the postmaster would block new connections.")));

	target = psbt_resolve_target(pid);
	if (!target.found)
	{
		ereport(WARNING,
				(errmsg("PID %d is not a PostgreSQL server process", pid)));
		return NULL;
	}

	psbt_check_permission(&target);

	return psbt_attach_and_capture((pid_t) pid);
}

/*
 * SQL: pg_get_backtrace(pid int) RETURNS text
 *
 * Returns the captured backtrace as text, or NULL if the pid did
 * not resolve to a PG process.  Permission failures and ptrace
 * errors raise ERROR.
 */
Datum
pg_get_backtrace(PG_FUNCTION_ARGS)
{
	int			pid = PG_GETARG_INT32(0);
	char	   *trace;
	text	   *result;

	trace = psbt_capture_for_pid(pid);
	if (trace == NULL)
		PG_RETURN_NULL();

	result = cstring_to_text(trace);
	pfree(trace);
	PG_RETURN_TEXT_P(result);
}

/*
 * SQL: pg_log_backtrace(pid int) RETURNS boolean
 *
 * Captures the backtrace (same mechanism as pg_get_backtrace) and
 * writes it to the server log at LOG level.  Returns true on success.
 *
 * Returns false (with WARNING) when the pid did not resolve to a PG
 * process.  Permission failures and ptrace errors raise ERROR.
 */
Datum
pg_log_backtrace(PG_FUNCTION_ARGS)
{
	int			pid = PG_GETARG_INT32(0);
	char	   *trace;

	trace = psbt_capture_for_pid(pid);
	if (trace == NULL)
		PG_RETURN_BOOL(false);

	/*
	 * Emit the captured trace as a LOG record.  We put the (one-line)
	 * banner in errmsg() and the (potentially many KB, multi-line)
	 * frame list in errdetail() because:
	 *
	 *   - errdetail is what csvlog / jsonlog put in their dedicated
	 *     "detail" column, so the frames stay structured and don't
	 *     interleave with log_line_prefix per-line repetition;
	 *   - some logging back-ends (notably syslog) cap a single
	 *     errmsg at a few KB and would silently truncate a long
	 *     frame list there, while errdetail is allowed to be long.
	 *
	 * elog/ereport handles internal '\n' inside the detail text as
	 * part of the message body; no escaping is required.
	 */
	ereport(LOG,
			(errmsg("backtrace of PID %d", pid),
			 errdetail("%s", trace)));

	pfree(trace);
	PG_RETURN_BOOL(true);
}
