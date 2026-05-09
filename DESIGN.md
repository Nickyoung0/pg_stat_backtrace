# pg_stat_backtrace — Design Notes

**Version**: 1.0
**Status**: Implementation complete; documentation and packaging follow
PostgreSQL contrib conventions.

This document records *why* the extension is built the way it is.  It is
intended as a companion to `README.md` (the user-facing documentation)
and to the inline comments in `pg_stat_backtrace.c`.  Reviewers and
future maintainers are the primary audience.


## 1. Goals

### 1.1 Functional goal

Provide a SQL-level interface that captures the C-level stack
backtrace of an arbitrary PostgreSQL process on the same host
**without requiring cooperation from the target process**.  Intended
diagnostic scenarios include:

- Stuck or looping backends.
- Backends holding locks for unusually long periods.
- `startup` / `walreceiver` whose WAL replay progress appears frozen.
- `autovacuum worker` / `walsender` with performance anomalies.
- Any process visible in `pg_stat_activity` whose state cannot be
  introspected from SQL alone.

### 1.2 Non-goals

- **Not** an always-on profiler — that is the job of `perf` / eBPF.
- **Not** a post-mortem tool — once a process is dead there is no
  stack to capture.
- **Not** portable to Windows / macOS — `ptrace(2)` semantics differ.
- **Not** a replacement for `pg_log_backend_memory_contexts()`, which
  logs PostgreSQL's internal memory-context tree rather than an OS-
  level call stack.

### 1.3 Design constraints

| Constraint | Rationale |
|------------|-----------|
| Minimal target pause (target < 10 ms typical) | Avoid disturbing production workload on the target. |
| Must work on a stuck target | That is the core use case; the design cannot assume the target can run code on its own. |
| Must work on auxiliary processes | `walsender` / `checkpointer` / `startup` are the processes operators most often want to inspect. |
| Must leave no residual state (no T-state, no altered signal mask) | Production tolerance for "works but leaves the process broken" is zero. |
| Must never silently swallow a signal destined for the target | Losing `SIGUSR1` would drop sinval invalidations or logical replication apply requests. |


## 2. Approach selection

### 2.1 Approaches considered and rejected

#### Approach I — Cooperative: `ProcSignal` + in-backend handler

**Idea**: add a `PROCSIG_CAPTURE_BACKTRACE`, have the target itself
walk its own stack from `CHECK_FOR_INTERRUPTS` and publish the result
through shared memory.

**Rejected because**:

- The target must actually reach `CHECK_FOR_INTERRUPTS`.  A stuck
  backend — precisely the case we care about most — never will.
- Running `backtrace()` or `libunwind` from within a signal handler is
  async-signal-unsafe and is prone to deadlock on the `malloc` lock.
- Unwinding inside the target's own address space consumes target
  stack, taints its `MemoryContext`, and can cause `ereport()` to
  fail.
- Auxiliary processes have no `sigsetjmp` / `longjmp` environment and
  cannot participate in this protocol at all.

For reference, `pg_log_backend_memory_contexts()` (PG14+) takes this
approach.  Its cost is exactly the limitations above: only
responsive backends can be inspected, and output goes only to the
server log.

#### Approach II — Read `/proc/<pid>/stack`

**Idea**: read the kernel stack from `/proc/<pid>/stack`; recover the
user-space stack separately.

**Rejected because**:

- `/proc/<pid>/stack` contains only the *kernel* call chain; nothing
  from PostgreSQL's C code is visible.
- Typically requires `root` + `CAP_SYS_ADMIN`.
- Many production kernels disable the interface entirely.

#### Approach III — External `perf` / eBPF sampling

**Idea**: capture stacks with `perf record` or `bpftrace`, symbolize
offline.

**Rejected because**:

- Requires a separate operations toolchain and cannot be triggered
  from SQL.
- Requires `root`, which DBAs usually do not have.
- Continuous sampling has non-trivial overhead.
- Well-suited to long-term profiling, ill-suited to "show me where
  this backend is stuck right now".

#### Approach IV — Classic `PTRACE_ATTACH` + `SIGSTOP`

**Idea**: `ptrace(PTRACE_ATTACH, pid)` → kernel injects `SIGSTOP` →
wait for stop → unwind → `PTRACE_DETACH` → kernel sends `SIGCONT`.

**Rejected because** (this is the most consequential decision in the
design):

- If the tracer dies mid-capture (OOM-kill, FATAL, segfault, `kill
  -9`), the kernel's auto-detach path delivers the pending
  attach-time `SIGSTOP` to the tracee.  The target is left in
  permanent `T` state and requires manual `kill -CONT`.  On a
  production database this is an outage.
- Signal-delivery-stop and attach-stop are indistinguishable on the
  `waitpid(2)` status word (both appear as `WIFSTOPPED` with
  `WSTOPSIG == SIGSTOP`), leading to race-induced misclassification.
- Under `sync-rep` / logical replication, contending with the
  target's real `SIGUSR1` creates a silent-drop risk.

### 2.2 Chosen approach: `PTRACE_SEIZE` + `PTRACE_INTERRUPT`

Core properties (Linux 3.4+, March 2012):

- `PTRACE_SEIZE(pid, 0, 0)` attaches **without stopping the target
  and without delivering any signal**.
- `PTRACE_INTERRUPT(pid)` stops the target at the next safe point;
  the resulting stop is reported via `waitpid(2)` with
  `status >> 16 == PTRACE_EVENT_STOP` (value 128), **unambiguously
  distinguishable** from a real signal-delivery-stop.
- If the tracer dies while attached, the kernel's auto-detach is
  clean — no stray `SIGSTOP` is delivered, and the target keeps
  running.

Costs:

- Requires Linux ≥ 3.4.  This is not a practical limit; the oldest
  kernels on any distribution supported by PG14+ are already ≥ 3.10.
- The state machine is slightly more involved (`PTRACE_EVENT_STOP`
  vs. signal-delivery-stop must be distinguished).  This is a
  one-time implementation cost and is encapsulated in
  `psbt_attach_and_capture` / `psbt_ptrace_detach_silent`.

Summary of the trade-off:

| Property | `PTRACE_ATTACH` | `PTRACE_SEIZE` | Verdict |
|----------|-----------------|----------------|---------|
| Safe on tracer crash | ❌ leaves `T`-state | ✅ clean auto-detach | **Decisive** |
| Signal classification | ❌ ambiguous | ✅ `EVENT_STOP` marker | Significant |
| Kernel requirement | 2.x | 3.4+ | Negligible |
| Code complexity | Low | Medium | Acceptable |


## 3. Architecture

### 3.1 Component layout

```
SQL caller
   │
   ▼
┌───────────────────────────────────────────────────────────────┐
│ SQL entry points                                              │
│   pg_get_backtrace(int)     → text                            │
│   pg_log_backtrace(int)     → bool                            │
└───────────────────────────────────────────────────────────────┘
   │
   ▼
┌───────────────────────────────────────────────────────────────┐
│ C orchestrator                                                │
│   psbt_capture_for_pid:  argument validation + pre-checks     │
│                                                               │
│   psbt_resolve_target:   atomic snapshot under ProcArrayLock  │
│                                                               │
│   psbt_check_permission: mirrors pg_signal_backend policy     │
│                                                               │
│   psbt_attach_and_capture:  ptrace state machine + unwind     │
└───────────────────────────────────────────────────────────────┘
   │
   ▼
┌───────────────────────────────────────────────────────────────┐
│ Platform layer                                                │
│   ptrace(2)  +  /proc/<pid>/status  +  libunwind(-ptrace)     │
└───────────────────────────────────────────────────────────────┘
```

### 3.2 File layout

| File | Role |
|------|------|
| `pg_stat_backtrace.c` | The complete C implementation (~1030 lines). |
| `pg_stat_backtrace--1.0.sql` | SQL function definitions and `REVOKE EXECUTE FROM PUBLIC`. |
| `pg_stat_backtrace.control` | Extension metadata. |
| `Makefile` | PGXS build with libunwind preflight checks (PIC link probe). |
| `meson.build` | Meson build recipe (PG16+, the version that introduced Meson). |
| `sql/pg_stat_backtrace.sql`, `expected/pg_stat_backtrace.out` | `pg_regress` regression test. |
| `t/*.pl` | TAP tests (PostgreSQL TAP framework). |
| `README.md` | User-facing documentation. |
| `DESIGN.md` | This document. |

### 3.3 Public API contract

- `pg_get_backtrace(pid int) → text`
  - Returns a `pstack(1)`-style multi-line text.
  - Invalid argument (`pid <= 0`, `pid` is not a PostgreSQL process):
    emits a `WARNING` and returns `NULL`.
  - Permission or `ptrace` failure: raises `ERROR`.

- `pg_log_backtrace(pid int) → bool`
  - Writes the backtrace to the server log at `LOG` level and
    returns `true`.
  - `errmsg()` contains a banner; `errdetail()` carries the frame
    text (which may be several KiB of multi-line output).
  - Invalid argument: `WARNING` and returns `false`.
  - Permission or `ptrace` failure: raises `ERROR`.

Function property contract (enforced in `pg_stat_backtrace--1.0.sql`):

- `STRICT` — a `NULL` input short-circuits to `NULL` result without
  entering C code.
- `PARALLEL RESTRICTED` — the function must run only in the leader;
  it is not safe for parallel workers.
- `VOLATILE` — every call has an externally visible side effect.

`SQLSTATE` classification:

| Condition | SQLSTATE | Error code |
|-----------|----------|------------|
| Invalid PID (`<= 0`) | — | `WARNING` only |
| Not a PostgreSQL process | — | `WARNING` only |
| `pid == MyProcPid` (self-attach) | `55000` | `OBJECT_NOT_IN_PREREQUISITE_STATE` |
| `pid == PostmasterPid` | `42501` | `INSUFFICIENT_PRIVILEGE` |
| Permission denied (PostgreSQL policy) | `42501` | `INSUFFICIENT_PRIVILEGE` |
| `yama.ptrace_scope` denies the attach | `42501` | `INSUFFICIENT_PRIVILEGE` |
| PID reuse crossing UID boundary | `42501` | `INSUFFICIENT_PRIVILEGE` |
| Target died mid-capture | `55000` | `OBJECT_NOT_IN_PREREQUISITE_STATE` |
| Attach deadline exceeded (3 s) | `55000` | `OBJECT_NOT_IN_PREREQUISITE_STATE` |
| Unexpected `waitpid(2)` outcome | `XX000` | `INTERNAL_ERROR` |


## 4. Key control flows

### 4.1 Happy-path capture

```
psbt_capture_for_pid(pid)
├── argument validation
│   ├── pid <= 0          → WARNING + NULL
│   ├── pid == MyProcPid  → ERROR 55000 (Linux forbids self-ptrace)
│   └── pid == PostmasterPid → ERROR 42501 (would block fork())
│
├── psbt_resolve_target(pid)         [atomic under ProcArrayLock LW_SHARED]
│   ├── BackendPidGetProcWithLock(pid) → regular backend
│   │       copies roleId into local snapshot
│   ├── AuxiliaryPidGetProc(pid)       → aux proc (has its own lock)
│   │       roleId := InvalidOid
│   └── neither found → found=false → caller emits WARNING + returns NULL
│
├── psbt_check_permission(snapshot)
│   ├── superuser()                    → allow
│   ├── is_aux                         → ERROR 42501 (no role to compare)
│   ├── role_id == InvalidOid          → ERROR 42501 (unauthenticated / avworker)
│   ├── superuser_arg(role_id) == true → ERROR 42501 (non-super cannot target super)
│   └── has_privs_of_role(role_id, current_user_id()) → allow
│
└── psbt_attach_and_capture(pid)
    ├── ptrace(PTRACE_SEIZE, pid, 0, 0)
    │       failure → ERROR 42501 with %m
    │
    ├── [PG_TRY begins]
    │   ├── ptrace(PTRACE_INTERRUPT, pid)
    │   │       ESRCH → ERROR 55000 "target exited before capture"
    │   │
    │   ├── wait loop (deadline 3 s, exponential backoff 0.1 ms → 10 ms)
    │   │   each iteration:
    │   │       waitpid(pid, &status, __WALL | WNOHANG)
    │   │       ├── WIFEXITED / WIFSIGNALED → ERROR 55000
    │   │       ├── WIFSTOPPED:
    │   │       │     ├── (status >> 16) == PTRACE_EVENT_STOP → break
    │   │       │     └── otherwise → ptrace(PTRACE_CONT, sig=WSTOPSIG)
    │   │       │                     reinject signal; continue
    │   │       └── deadline hit → ERROR 55000 with errhint
    │   │
    │   ├── psbt_verify_target_uid(pid)
    │   │       reads /proc/<pid>/status "Uid:" line
    │   │       compares with geteuid()
    │   │       mismatch → ERROR 42501 "PID recycled"
    │   │
    │   ├── libunwind capture
    │   │       unw_create_addr_space + _UPT_create(pid) + unw_init_remote
    │   │       iterate unw_step, append frames to StringInfoData
    │   │
    │   └── psbt_ptrace_detach_silent(pid)
    │       [normal exit]
    │
    └── [PG_CATCH]
        └── psbt_ptrace_detach_silent(pid); PG_RE_THROW()
```

### 4.2 Silent detach (`psbt_ptrace_detach_silent`)

This function is invoked on **every** exit path (normal and
`PG_CATCH`).  Goal: regardless of the tracee's current state, detach
cleanly and **never swallow a pending signal** destined for the
tracee.

```
psbt_ptrace_detach_silent(pid)
├── fast path: ptrace(PTRACE_DETACH, pid, 0, 0)
│       success → return
│       ESRCH   → tracee already dead; return
│       other   → fall through
│
├── ptrace(PTRACE_INTERRUPT, pid)
│       ESRCH → tracee dead; return
│
├── drain loop (up to ~100 iterations ≈ 100 ms)
│   each iteration:
│       waitpid(pid, &status, __WALL | WNOHANG)
│       ├── WIFEXITED / WIFSIGNALED → return (dead)
│       ├── WIFSTOPPED:
│       │     ├── (status >> 16) == PTRACE_EVENT_STOP → break
│       │     └── otherwise → ptrace(PTRACE_CONT, sig=WSTOPSIG); continue
│       └── pg_usleep(1000)  [EINTR is harmless; we do not call
│                              CHECK_FOR_INTERRUPTS in this helper]
│
└── final detach
    ├── if a pending signal is visible:
    │       ptrace(PTRACE_DETACH, pid, 0, WSTOPSIG)
    │           — detach-with-signal; the pending signal is delivered
    │             exactly once as the detach completes, preserving the
    │             "we must never silently swallow a signal" invariant.
    └── otherwise:
            ptrace(PTRACE_DETACH, pid, 0, 0)
```

Key points:

- This helper **deliberately does not call `CHECK_FOR_INTERRUPTS()`**.
  Rationale: if this path were to raise `ERROR`, the tracee would be
  left in `T` state until the backend exits.  Spending up to 100 ms
  to complete the detach is strictly better than that outcome.
- `errno` is saved and restored around every `ptrace` / `waitpid` /
  `pg_usleep` call so that the caller's subsequent
  `ereport(ERROR, ... errmsg("... %m", ...))` observes the **original**
  `errno` from the failing operation, not an `errno` leaked from the
  detach helper.

### 4.3 `WIFSTOPPED` classification

```
waitpid returned status N with WIFSTOPPED(N) == true
│
├── (N >> 16) == PTRACE_EVENT_STOP  (128)
│   │
│   ├── the stop we triggered via PTRACE_SEIZE + PTRACE_INTERRUPT
│   ├── or a SEIZE-observed group-stop
│   │   (SIGSTOP / SIGTSTP / SIGTTIN / SIGTTOU arrived at the target)
│   └── both are treated as "ready to detach"                     ✅
│
└── (N >> 16) == 0
    └── signal-delivery-stop: the target is about to receive a real
        signal; WSTOPSIG(N) names it.
        MUST resume with ptrace(PTRACE_CONT, pid, 0, WSTOPSIG) so
        that the signal is delivered once we continue the tracee.
        Silently consuming such a stop would violate the "never
        swallow a signal" contract.
```


## 5. Concurrency and race analysis

### 5.1 PID-reuse race

**Scenario**: after `psbt_resolve_target` returns but before
`ptrace(PTRACE_SEIZE)` runs, the target exits and the kernel
recycles the PID for an unrelated process — possibly owned by a
different UID.

**Defenses**:

1. The snapshot taken under `ProcArrayLock` in `LW_SHARED` mode
   prevents the PGPROC slot from being reassigned to **another
   PostgreSQL backend** between reading `roleId` and calling
   `ptrace`.  (Slot reuse is the in-PG race; this closes it.)
2. After a successful `PTRACE_SEIZE`, we re-read
   `/proc/<pid>/status` and compare the `Uid:` line against
   `geteuid()`.  This closes the remaining case: PID recycled to a
   **non-PostgreSQL** process.  (If the recycled process also happens
   to run under our UID, it is still blocked — this check is
   intentionally stricter than necessary.)
3. `kernel.yama.ptrace_scope ≥ 1` provides kernel-level enforcement
   as well, but the design does not rely on it.

### 5.2 Concurrent sessions targeting the same PID

Linux `ptrace(2)` allows **at most one tracer per tracee**.  A second
session's `PTRACE_SEIZE` returns `EPERM`.

Our behavior:

- Error message: `could not attach to PID N via ptrace: Operation
  not permitted`.
- `errhint()` mentions both `yama.ptrace_scope` and the "same UID"
  requirement.
- `SQLSTATE` is `42501` (`INSUFFICIENT_PRIVILEGE`).

Known limitation: the error text does not distinguish "yama
ptrace_scope denies" from "another session is currently attached".
Both produce `EPERM` and both are surfaced here.  `README.md` calls
this out explicitly.

### 5.3 `ProcArray` slot reassignment

**Scenario**: `BackendPidGetProc(pid)` returns, then — before we
dereference `proc->roleId` — the PGPROC slot is reused by a newly
arriving backend.  The `roleId` we read no longer belongs to the PID
we think we are inspecting.

**Defense**: use `BackendPidGetProcWithLock(pid)` together with an
explicit `LWLockAcquire(ProcArrayLock, LW_SHARED)`, and copy
`roleId` **inside** the critical section.  The snapshot is
consistent.

**Contrast**: in-core `pg_signal_backend` uses the lock-free
`BackendPidGetProc` + direct access to `proc->roleId`.  The race
window exists there too, but the worst outcome is a signal
delivered to a freshly launched backend — recoverable.  `ptrace`
attachment is much more consequential, so this extension uses the
stronger contract.

### 5.4 Tracee dies mid-capture

| At which point | Observable | Handling |
|-----|-----|-----|
| Before `SEIZE` | `SEIZE` returns `-1 / ESRCH` | `ERROR 42501` |
| After `SEIZE`, before `INTERRUPT` | `INTERRUPT` returns `-1 / ESRCH` | `ERROR 55000`, `attached=false` |
| After `INTERRUPT`, during wait loop | `waitpid` reports `WIFEXITED` / `WIFSIGNALED` | `ERROR 55000`, `attached=false` |
| During unwind | `libunwind` `ptrace` peek returns an error; `unw_step` returns `< 0` | Break out of the unwind loop normally; detach's fast path returns `ESRCH` and completes. |
| During detach | fast-path `PTRACE_DETACH` returns `-1 / ESRCH` | `psbt_ptrace_detach_silent` recognizes this and returns. |

No path leaks a lingering `ptrace` attachment.

### 5.5 Tracer (this backend) dies mid-capture

Scenarios: the backend is killed by the OOM-killer, hit by `FATAL`,
segfaults, or receives `kill -9`.

Kernel behavior under `PTRACE_SEIZE`: **auto-detach with no signal
delivered to the tracee**.  The target continues running unharmed.

This is the primary reason for choosing `PTRACE_SEIZE` over
`PTRACE_ATTACH`.

### 5.6 Signal storm race

Multiple signals are being delivered to the target concurrently
(for instance: postmaster sends `SIGTERM`, another backend sends
`SIGUSR1`, and a timeout fires `SIGALRM`).

The wait loop handles each `WIFSTOPPED` event as follows:

1. Classify — is it `PTRACE_EVENT_STOP`?
2. If not, `ptrace(PTRACE_CONT, pid, 0, WSTOPSIG(status))` reinjects
   the signal.
3. Continue waiting.

Worst realistic case: three pending signals ahead of `EVENT_STOP`,
four `waitpid` iterations.  Each non-blocking `waitpid` is < 1 µs,
so the additional overhead is well under 100 µs — well within the
3-second attach deadline.


## 6. Resource lifecycle

### 6.1 Memory

| Resource | Allocation | Release | Exception path |
|----------|------------|---------|----------------|
| `StringInfoData buf` | `initStringInfo(&buf)` | Current `MemoryContext` reset | Same — no leak. |
| `buf.data` returned to caller | `palloc` in current context | Caller `pfree` or context reset | Same. |
| `unw_addr_space_t as` | `unw_create_addr_space` | `unw_destroy_addr_space` | Released explicitly in `PG_CATCH`. |
| `void *upt` | `_UPT_create(pid)` | `_UPT_destroy(upt)` | Released explicitly in `PG_CATCH`. |
| `text *result` | `cstring_to_text(trace)` | Expression context reset | — |
| Symbol buffer `sym[512]` | On stack | Automatic | — |

No-leak argument:

- `psbt_capture`: libunwind resources are wrapped in `PG_TRY`; both
  the `CATCH` and the normal exit call `_UPT_destroy` +
  `unw_destroy_addr_space`.
- `psbt_attach_and_capture`: the `attached` `volatile` flag
  arbitrates detach.  The `PG_CATCH` detaches on error; the happy
  path detaches before returning.
- All `palloc`s are in the current `MemoryContext`.  Context reset
  reclaims everything; explicit `pfree` is not required.

### 6.2 Kernel file descriptors

The only fd used is `fopen("/proc/<pid>/status", "r")` in
`psbt_verify_target_uid`:

- The fd lives in the local scope; `fclose` is called in every
  branch.
- The helper contains no `ereport(ERROR)` and no
  `CHECK_FOR_INTERRUPTS` call site between `fopen` and `fclose`
  (only `fopen` / `fgets` / `fclose` / `sscanf`), so there is no
  `longjmp`-induced fd leak.

### 6.3 `ptrace` attach relationship

**Guarantee**: once `PTRACE_SEIZE` has succeeded, every exit path
(normal or `ERROR`) passes through `psbt_ptrace_detach_silent`.

This is enforced jointly by `PG_TRY` / `PG_CATCH` and the outer
`attached` `volatile` flag.  See `psbt_attach_and_capture` for the
exact shape.

### 6.4 LWLock

The `ProcArrayLock` hold time is minimal:
`LWLockAcquire` → `BackendPidGetProcWithLock` → copy a single `Oid`
→ `LWLockRelease`.  **No function inside the critical section can
`ereport`**, so there is no risk of holding the lock across a
`longjmp`.

### 6.5 `longjmp` safety (`volatile`)

`PG_CATCH` is implemented with `siglongjmp(3)`.  Per POSIX §7.1.2.1
and C11 §7.13.2.1, a local variable that is modified between
`setjmp` and `longjmp` has an **unspecified value after `longjmp`
unless it is declared `volatile`**.

Variables in this extension that are modified after a `setjmp` and
read in `PG_CATCH`:

- `volatile bool attached` — arbitrates whether `detach_silent` must
  run on the error path.
- `volatile unw_addr_space_t as` / `volatile void *upt` — used in
  `psbt_capture` for the same reason.

`-Wclobbered` at `-Wall -Wextra` is clean on all currently-supported
PostgreSQL versions, which is our validation signal for this
property.


## 7. Error-handling strategy

### 7.1 Error-message conventions

The extension follows the PostgreSQL message style guide strictly:

- `errmsg()` — **lowercase** first word, no trailing period (unless
  the message is multiple sentences).  Dynamic data is interpolated
  with `%d` / `%s` / `%m`.
- `errdetail()` — full sentences: **uppercase** first word, trailing
  period.
- `errhint()` — imperative sentences: **uppercase** first word,
  trailing period.

Every `ERROR` carries an explicit `errcode()`.

### 7.2 `WARNING` vs. `ERROR`

| Condition | Level | Rationale |
|-----------|-------|-----------|
| `pid <= 0` | `WARNING` | Allows `SELECT pg_get_backtrace(pid) FROM ...` to continue iterating. |
| PID is not a PG process | `WARNING` | Same iterator-friendly rationale. |
| Self-PID | `ERROR` | Programming error; must be visible. |
| Postmaster | `ERROR` | Safety boundary. |
| Permission denied | `ERROR` | PostgreSQL convention. |
| `ptrace` syscall failure | `ERROR` | System-level fault. |
| Target died mid-capture | `ERROR` | The request cannot be fulfilled. |

The distribution here matches the conventions used by
`pg_signal_backend()` and `pg_log_backend_memory_contexts()` — both
of which return booleans and use `WARNING` for "nothing to do" and
`ERROR` for "caller violated a contract".

### 7.3 `%m` usage

Where `ptrace(2)` fails, the immediately-following
`ereport(ERROR, errmsg("... %m", ...))` expands `%m` from `errno` as
set by the failing syscall.

To keep this reliable, `psbt_ptrace_detach_silent` and
`psbt_verify_target_uid` save `errno` at entry and restore it at
exit, preventing cleanup paths from stomping on the `errno` the
caller wants to report.


## 8. Performance

### 8.1 Happy-path time budget

Measured on x86_64 / Linux 5.10 with a backend at stack depth ≈ 30:

| Stage | Typical |
|-------|---------|
| Argument validation | < 10 µs |
| `psbt_check_permission` (SysCache hit) | < 50 µs |
| `PTRACE_SEIZE` | < 50 µs |
| `PTRACE_INTERRUPT` | < 50 µs |
| Wait for `EVENT_STOP` (kernel scheduling) | 100 µs – 1 ms |
| `psbt_verify_target_uid` (`/proc` read) | ≈ 50 µs |
| `libunwind` setup | ≈ 100 µs |
| Per-frame unwind (`ptrace` peek × N + symbol lookup) | ≈ 100 µs / frame |
| 30 frames × 100 µs | ≈ 3 ms |
| `PTRACE_DETACH` | < 50 µs |

Target pause time ≈ "wait for `EVENT_STOP`" through `PTRACE_DETACH`
— typically **1–5 ms**.

### 8.2 Worst case

- 256-frame cap reached: ≈ 26 ms target pause.
- Signal storm (10+ reinjections): + ≈ 10 ms.
- Attach-phase deadline: 3 s (target is wedged in an uninterruptible
  syscall — very rare).
- Detach drain: 100 ms (same cause).

### 8.3 Impact on the target's workload

While the target is stopped:

- If it holds any `LWLock` or heavyweight lock, **every waiter on
  that lock is also blocked**.
- If it is a `walsender` with synchronous replication, the
  corresponding commit waiters stall.
- If it is the `checkpointer` or `walwriter`, checkpoint progress
  and WAL flushing stall.

`README.md` — "Operational risk" section — enumerates which target
roles warrant particular caution in production.

### 8.4 Caller overhead

Per call, in the caller's `MemoryContext`:

- One `StringInfoData buf` (initially 1 KiB, extended per frame;
  typically 3–5 KiB at final size).
- Intermediate `palloc`s driven by `StringInfo`.

Nothing long-lived is allocated.  No `SysCache` entry is appended,
no shared memory is touched.


## 9. Security model

### 9.1 Layered defences

1. **SQL layer** — `REVOKE EXECUTE ... FROM PUBLIC`.  By default
   only a superuser can invoke either function.
2. **C pre-checks** —
   - Self-PID and postmaster PID are rejected immediately.
   - `psbt_resolve_target` snapshots `roleId` under `ProcArrayLock`.
   - `psbt_check_permission` mirrors `pg_signal_backend`'s policy.
3. **`ptrace` layer** — the OS enforces
   `kernel.yama.ptrace_scope` and capability constraints.
4. **UID second-check** — after a successful `PTRACE_SEIZE`, we
   re-read `/proc/<pid>/status` and compare `Uid:` against
   `geteuid()`.
5. **`PARALLEL RESTRICTED`** — prevents accidental invocation from a
   parallel worker.

### 9.2 Permission matrix

| Caller | Target | Result |
|--------|--------|--------|
| Superuser | Any PG process | Allow. |
| Non-superuser | Its own backend | ⚠️ Rejected — Linux forbids self-`ptrace`. |
| Non-superuser | Another backend under the same role | Allow. |
| Non-superuser | Backend under a role of which the caller has membership | Allow (`has_privs_of_role`). |
| Non-superuser | Superuser's backend | Reject (mirrors `pg_signal_backend`). |
| Non-superuser | Aux proc (WAL / checkpointer / …) | Reject (no role to compare). |
| Non-superuser | Autovacuum worker | Reject (`roleId = InvalidOid`). |
| Non-superuser | Unauthenticated backend | Reject (`roleId = InvalidOid`). |

### 9.3 Threat surface

| Threat | Mitigation |
|--------|------------|
| Non-superuser reads another user's stack | Layered permission checks. |
| PID reuse — read a non-PG process | UID second-check. |
| PID reuse — read a `root` process | UID second-check (cross-UID reads are blocked at the source). |
| Signal swallowed, perturbing target state | Reinject during wait; detach-with-signal at finalize. |
| Tracer crash leaves `T`-state target | `PTRACE_SEIZE` guarantees clean kernel auto-detach. |
| Format-string injection via frame text | `errdetail("%s", trace)` form — never `errdetail(trace)`. |
| `ProcArray` race reads stale `roleId` | Atomic snapshot under `ProcArrayLock`. |
| Excessive output causing DoS | 256-frame cap; 512-byte symbol cap. |


## 10. Platform compatibility

### 10.1 OS / architecture

| Dimension | Supported | Rationale |
|-----------|-----------|-----------|
| Linux x86_64 | ✅ primary | `ptrace` + `/proc` + libunwind all available. |
| Linux aarch64 | ✅ | libunwind supports it. |
| Linux ppc64le | ✅ | libunwind supports it. |
| Linux s390x | ✅ | libunwind supports it. |
| Linux riscv64 | ⚠️ | Requires libunwind 1.8+. |
| Linux loongarch64 | ⚠️ | Requires libunwind master. |
| FreeBSD | ❌ | `ptrace` semantics differ; no `PTRACE_SEIZE` equivalent; `/proc` layout differs. |
| macOS | ❌ | `ptrace` is severely restricted; `task_for_pid` requires entitlements. |
| Windows | ❌ | No `ptrace`. |

Non-x86_64 Linux support is provided by libunwind; the extension
itself is architecture-agnostic (everything goes through DWARF CFI
exposed by `libunwind-generic`).

### 10.2 PostgreSQL version

| Version | Supported | Notes |
|---------|-----------|-------|
| 14 | ✅ | `PG_MODULE_MAGIC` branch. |
| 15 | ✅ | Same. |
| 16 | ✅ | Same. |
| 17 | ✅ | Same. |
| 18 | ✅ | `PG_MODULE_MAGIC_EXT` branch. |
| 19 (master) | ✅ | Same. |

All backend APIs the extension uses — `BackendPidGetProcWithLock`,
`AuxiliaryPidGetProc`, `has_privs_of_role`, `superuser_arg`,
`TimestampTzPlusMilliseconds` — have been stable since well before
PG 9.6.

### 10.3 libunwind version

Minimum: libunwind 0.99 (2006).  Recommended: 1.6+ for stable DWARF
CFI behavior.

### 10.4 Kernel version

- `PTRACE_SEIZE` / `PTRACE_INTERRUPT` / `PTRACE_EVENT_STOP` — Linux
  3.4+ (March 2012).
- `__WALL` flag for `waitpid(2)` — Linux 2.4+.
- `/proc/<pid>/status` `Uid:` line — stable since Linux 2.4.


## 11. Build system

### 11.1 Dependency detection (Makefile)

```
1. Check libunwind.h                           → $(error ... libunwind-devel/-dev)
2. Check libunwind-ptrace.so is present        → $(error ... need .so, install
                                                   libunwind-devel or build from
                                                   source)
3. Run a real PIC link probe:
       gcc -shared -fPIC probe.c -lunwind-ptrace -lunwind-generic -lunwind
                                               → $(error with actionable hint
                                                   when the distro ships a
                                                   non-PIC .a)
4. All checks pass → proceed with the normal PGXS build.
```

The third step exists specifically to catch "`libunwind-devel` is
installed but ships only a non-PIC `.a`", which otherwise produces a
cryptic `R_X86_64_PC32` relocation error at link time.  See
`README.md` — "Installation rule" — for the resolution.

### 11.2 Meson support (PG16+)

`meson.build` gracefully skips the build if libunwind cannot be
found (`subdir_done()`), matching the convention used by
`contrib/sepgsql/meson.build`.  This is only relevant when the
extension is placed in the PostgreSQL source tree.  Meson became
the preferred build system upstream starting in PostgreSQL 16.


## 12. Testing strategy

### 12.1 Regression tests (`pg_regress`)

Covers **platform-agnostic** metadata:

- `CREATE EXTENSION` / `DROP EXTENSION` succeed.
- Function signatures are exactly as declared (`pronargs`,
  `provolatile = 'v'`, `proisstrict = true`, `proparallel = 'r'`,
  `prorettype`).
- `REVOKE EXECUTE FROM PUBLIC` is in effect.
- `STRICT` short-circuits `NULL` input.

This suite deliberately does **not** cover actual unwind output,
since the output depends on architecture, optimization level, debug
info availability, and `yama.ptrace_scope`.

### 12.2 TAP tests

Located under `t/`, registered in `Makefile` (`TAP_TESTS = 1`) and
`meson.build` (`tests.tap.tests = [...]`).  Scripts `skip_all` when
`$^O ne 'linux'`; scripts requiring real `ptrace` privileges
additionally `skip_all` when `kernel.yama.ptrace_scope > 1`, so
locked-down CI environments do not produce false positives.

| File | Coverage | Needs `ptrace` | Assertions |
|------|----------|----------------|------------|
| `t/001_basic.pl` | function signature, default privileges, STRICT, bad PID, self-target, DROP/CREATE loop | ❌ | 10 |
| `t/002_permission.pl` | non-super without grant is rejected, non-super cannot target super, role-membership path | ❌ | 7 |
| `t/003_capture.pl` | real backend capture, aux-proc capture, `pg_log_backtrace` writes to log, output size bound | ✅ | 11 |
| `t/004_target_lifecycle.pl` | target exits before capture, target killed mid-capture, 20-iteration loop with no residual state, `T`-state detection | ✅ | 7 |
| `t/005_concurrent.pl` | two sessions on the same PID (`EPERM 42501` or `55000` state race), multiple sessions on distinct PIDs | ✅ | 3 |
| **Total** | | | **38** |

Representative assertion patterns:

- **Format contract**:
  `qr/^#\d+\s+0x[0-9a-f]+\s+in\s+\S+\+0x[0-9a-f]+/m`.
- **State health**: read `/proc/<pid>/status` and assert `State:`
  is not `T`.
- **No residual attachment**: read `/proc/<pid>/status` and assert
  `TracerPid:` is `0`.
- **Error classification**: `SQLSTATE` on concurrent-capture failure
  must be in `{42501, 55000}` — never `XX000`.

How to run:

```
# All TAP tests
make check              # in the extension directory

# A single TAP test
make check PROVE_TESTS=t/003_capture.pl

# Via Meson (in-tree build)
meson test -C build pg_stat_backtrace/regress
meson test -C build pg_stat_backtrace/001_basic
```

### 12.3 Manual / production validation checklist

| # | Scenario | Command | Expected |
|---|----------|---------|----------|
| 1 | Regular backend | `SELECT pg_get_backtrace(<pid>)` | pstack-style output. |
| 2 | `walsender` | same | Output contains `WalSndLoop` or similar. |
| 3 | `walwriter` | superuser | Output contains `WalWriterMain`. |
| 4 | autovacuum worker | superuser | Output contains `do_autovacuum`. |
| 5 | Self-target | `SELECT pg_get_backtrace(pg_backend_pid())` | `ERROR 55000`. |
| 6 | Postmaster | | `ERROR 42501`. |
| 7 | Non-super targets super | | `ERROR 42501`. |
| 8 | Target dies mid-capture | kill + capture | `ERROR 55000` "exited". |
| 9 | Two sessions race on same PID | | One raises `ERROR 42501 EPERM`. |
| 10 | PID = `-1`, `0`, `99999999` | | `WARNING` + `NULL`. |
| 11 | Cancel in-flight capture | `\x` + Ctrl-C | Returns promptly; target detached. |
| 12 | `pg_log_backtrace` writes to server log | | Log shows "backtrace of PID ...". |


## 13. Known limitations

### 13.1 Functional limits

- Same-UID requirement (the `postgres` OS user cannot inspect a
  `root` process).
- `kernel.yama.ptrace_scope` must be `0` or `1` (`0` recommended).
- Symbol resolution depends on the target binary's debug info /
  symbol table.  A fully stripped binary yields only addresses.
- Kernel stack frames are invisible to `ptrace`.
- PLT and dynamic-linker internal frames are not expanded (libunwind
  default behavior).

### 13.2 Performance limits

- Target pause typically 1–10 ms; pathologically up to ~100 ms.
- Repeatedly capturing the same high-QPS target will measurably
  degrade its throughput.

### 13.3 Correctness limits

- Tail-call-optimized frames may be collapsed (a DWARF CFI property,
  not fixable here).
- Inline frames: libunwind 1.8+ supports DWARF inline info; older
  versions show only physical frames.
- For C++ targets, symbols are mangled (no demangling is performed).


## 14. Future work

### 14.1 Pre-submission checklist

| Item | Effort | Status |
|------|--------|--------|
| SGML documentation (`doc/src/sgml/pgstatbacktrace.sgml`) | ~3 h | ⏳ |
| Register in `contrib/Makefile` and `contrib/meson.build` | ~10 min | ⏳ |
| Fold `README.md` content into the SGML chapter | ~30 min | ⏳ |
| Naming review (`pg_stat_*` namespace convention) | community feedback | ⏳ |

### 14.2 Feature enhancement candidates

- **Optional demangling**: call `__cxa_demangle` on the name
  returned by `unw_get_proc_name` for C++ targets.
- **Inline frame expansion**: enable libunwind 1.8 inline info
  support.
- **GUC-ify limits**: expose `PSBT_MAX_FRAMES` and
  `PSBT_ATTACH_WAIT_SECS` as GUCs.
- **Batch API**: `pg_log_backtrace(VARIADIC int[])` to capture many
  PIDs in one call.
- **Snapshot to file**: `pg_get_backtrace_to_file(pid, path)` to
  sidestep `errmsg` / `errdetail` size limits.
- **Source-line information**: `file:line` in the output — requires
  either `addr2line` integration or libunwind inline info.

### 14.3 Possibilities beyond the current hard constraints

- **libunwind-free fallback**: use `backtrace(3)` plus
  `/proc/<pid>/maps` to perform a minimal unwind.  Trade-off: only
  addresses, no symbols; does not work on binaries built without
  frame pointers.  Upside: removes the libunwind build dependency.
- **Kernel-assisted capture**: have the kernel record stacks via
  `bpf_get_stackid`, avoiding `ptrace` entirely.  Trade-off:
  requires eBPF and a newer kernel.  Upside: zero target pause.


## 15. References

- Linux `ptrace(2)` manual page, in particular the section on
  `PTRACE_SEIZE` / `PTRACE_INTERRUPT` / `PTRACE_EVENT_STOP`.
- Linux `waitpid(2)` and `wait(2)` — status-word semantics.
- libunwind documentation — `unw_create_addr_space`,
  `_UPT_create`, `unw_init_remote`, `unw_step`,
  `unw_get_proc_name`.
- PostgreSQL source: `src/backend/storage/ipc/procarray.c`
  (`BackendPidGetProcWithLock`, `AuxiliaryPidGetProc`),
  `src/backend/utils/adt/misc.c` (`pg_signal_backend`),
  `src/backend/utils/error/elog.c` (`ereport` / `errcode` / `%m`).
- PostgreSQL error-message style guide:
  `doc/src/sgml/sources.sgml`, "Error Message Style Guide".
- POSIX.1-2008 §7.1.2.1 (`setjmp` / `longjmp` semantics).
