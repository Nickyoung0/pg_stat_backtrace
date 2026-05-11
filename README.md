# pg_stat_backtrace &mdash; capture C-level stack backtraces of PostgreSQL processes

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14%20%7C%2015%20%7C%2016%20%7C%2017%20%7C%2018%20%7C%2019-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![Platform](https://img.shields.io/badge/platform-linux-blue)]()
[![License](https://img.shields.io/badge/license-PostgreSQL-blue.svg)](./LICENSE)

The `pg_stat_backtrace` module provides a means for capturing the
C-level stack backtrace of any PostgreSQL process running on the
same host, from SQL.  PostgreSQL itself does not ship a SQL
function that returns the C-level stack of an arbitrary backend
or auxiliary process: `pg_log_backend_memory_contexts(pid)` (PG14+)
logs *memory contexts*, not a call stack, and the
`backtrace_functions` GUC only triggers an in-process backtrace
when a specific C function raises an error.  `pg_stat_backtrace`
fills that gap.  Unlike the in-core memory-context path, it does
**not** send a signal to the target; it attaches with
`ptrace(PTRACE_SEIZE)` (Linux 3.4+), briefly halts the target
with `PTRACE_INTERRUPT` (a pure ptrace event -- **no `SIGSTOP`
is ever sent**), unwinds the stack with `libunwind` (DWARF CFI
based) via the `libunwind-ptrace` accessors, and detaches.

The module is not available globally but can be enabled for a
specific database with `CREATE EXTENSION pg_stat_backtrace`.

## Functions

| Function | Returns | Effect |
|---|---|---|
| `pg_get_backtrace(pid int)` | `text` | Return the captured backtrace as text. |
| `pg_log_backtrace(pid int)` | `boolean` | Write the captured backtrace to the server log at `LOG` level. Returns `true` on success. |

Both functions are declared `VOLATILE STRICT PARALLEL RESTRICTED`:
* **`STRICT`** -- a `NULL` `pid` argument short-circuits to
  `NULL` (for `pg_get_backtrace`) or `NULL` (for
  `pg_log_backtrace`) without entering the C body, so no ptrace
  attempt is made;
* **`VOLATILE`** -- the result depends on the target's live
  call stack and must not be cached or reordered by the planner;
* **`PARALLEL RESTRICTED`** -- must execute in the leader; not
  safe to run inside a parallel worker (the worker's backend
  identity is not the caller's).

Both functions take a single `pid` argument (the PostgreSQL
backend or auxiliary process to introspect) and follow the
permission model described below.  Non-positive PIDs produce a
`WARNING` and return `NULL` / `false` without touching `ptrace`.
The output format mimics `pstack(1)`:

```
#0  0x00007f5e6c1a4d9e in __epoll_wait+0x4e
#1  0x000055f1a8c2a213 in WaitEventSetWaitBlock+0x83
#2  0x000055f1a8c2a04e in WaitEventSetWait+0xfe
...
```

## Permission model

| Caller | Can target |
|---|---|
| Superuser | Any PG process in this instance, **including auxiliary processes** (walwriter, checkpointer, walsender, autovacuum launcher / worker, startup, archiver, walsummarizer on PG17+, AIO io worker on PG18+, ...) |
| Non-superuser | Only regular backends running under a role they have membership in.  Auxiliary processes have no role and are always rejected. |

This mirrors the policy of PostgreSQL's predefined
`pg_signal_backend` role (and the in-core `pg_signal_backend()`
helper that enforces it).  A non-superuser may not target a
backend owned by a superuser, even with role membership.

By default `EXECUTE` is `REVOKE`'d from `PUBLIC` for both functions;
a site administrator may `GRANT EXECUTE` to a specific monitoring
role and the C code will still enforce the role-membership check
above.

## Notes

### Safety checks

* **Self** (`pid == MyProcPid`) is rejected: a process cannot
  ptrace itself on Linux.  Run the function from a different
  session if you want your own backtrace.
* **Postmaster** is rejected: pausing it would block `fork()`
  of new connections.
* The target's **real UID is re-verified** after `PTRACE_SEIZE` to
  close the narrow PID-reuse race window between
  `BackendPidGetProc()` and `ptrace()`.
* The target's `roleId` is snapshotted **under `ProcArrayLock`** to
  prevent a concurrent slot reassignment from leaking unintended
  access.
* The target is briefly paused (typically single-digit
  milliseconds) via `PTRACE_INTERRUPT` and resumed before the
  function returns.
* Frame depth is capped at 256 to bound runaway-recursion output.
* **No signals are ever injected into the target.** The extension
  uses `PTRACE_SEIZE` + `PTRACE_INTERRUPT` (Linux 3.4+) rather
  than the classic `PTRACE_ATTACH` + `SIGSTOP`.  `SEIZE` attaches
  without stopping the target and without delivering any signal;
  `INTERRUPT` produces a pure `PTRACE_EVENT_STOP` that is not a
  signal.  Consequence: if the calling backend crashes
  mid-capture (OOM killer, FATAL, segfault), the kernel
  auto-detaches cleanly; the target does not end up stuck in T
  state with a pending SIGSTOP that would require manual
  SIGCONT to recover.
* **No signals are silently swallowed.** While we wait for our
  own interrupt-induced stop, other pending signals on the target
  (e.g. `SIGUSR1` from `procsignal`, `SIGTERM` from a shutdown)
  may be observed first as signal-delivery-stops.  ptrace(2)
  explicitly warns about this race; the extension re-injects
  those signals via `PTRACE_CONT` and keeps waiting, so a
  backtrace call can never lose a `sinval` invalidation, a
  logical-replication apply request, or a graceful shutdown
  signal aimed at the target.

### Operational risk: targets that hold critical locks

When you pause a backend that currently holds a heavily
contended LWLock or a critical HWlock, **every other process that
needs that lock will block** for the duration of the unwind
(typically single-digit milliseconds, but no hard upper bound if
the kernel scheduler is loaded).  A few targets where this matters
in practice:

| Target | Locks/state held while sleeping | What stalls during the unwind |
|---|---|---|
| `walwriter` | `WALWriteLock` (during a flush) | Backends waiting to commit |
| `checkpointer` | no single "big" lock; during `BufferSync` it briefly holds buffer-header spinlocks and `BufMappingPartitionLock` to write out dirty buffers, and serves checkpoint requests via `CheckpointerCommLock` | Backends waiting on the same buffer partition; requesters of `CHECKPOINT` |
| `walsender` (with `synchronous_standby_names` set) | not a lock, but the sync-rep ack loop is blocked | **All synchronous-commit transactions on the primary stall** until the unwind completes |
| `walsender` (asynchronous) | nothing critical, but the network buffer drains | Replica may briefly fall behind |
| `startup` (during recovery) | recovery-progress locks | Recovery progress, hot_standby_feedback |
| Backend running `VACUUM FULL` | `AccessExclusiveLock` on a relation | Any session touching that relation |

In normal use (a few hundred milliseconds total per call) this is
harmless.  Avoid wrapping it in tight loops against critical
helpers, and avoid running it against `walwriter` /
`checkpointer` on a primary that is already write-saturated.

> ⚠️ **Synchronous replication trap**: if the calling session is
> itself inside a transaction with `synchronous_commit=on` and the
> standby is the only one acknowledging WAL, calling
> `pg_get_backtrace()` against the primary's `walsender` would
> pause the very process the caller's commit is waiting for.
> The unwind itself is bounded (~10 ms) so this resolves on its
> own, but in pathological scenarios (many concurrent sync-rep
> commits + repeated calls) it can compound into noticeable
> commit latency.  Prefer running such introspection from a
> non-writing monitoring session.

### Concurrency

Linux's `ptrace(2)` enforces **at most one tracer per tracee**.
If two sessions call `pg_get_backtrace(<same pid>)` at the same
moment, the loser's `PTRACE_SEIZE` will fail with `EPERM` and the
extension surfaces this as
`ERROR: could not attach to PID N via ptrace: Operation not permitted`.
The error hint mentions `ptrace_scope`, but the actual cause may
simply be another in-flight call against the same target.  Retry
after a few milliseconds.

## Build dependencies

`pg_stat_backtrace` requires `libunwind` + `libunwind-ptrace`
**at build time**.  There is no in-process / signal-based fallback
path -- if those libraries are missing the build aborts rather than
ship a stub.

| Distro | Package |
|---|---|
| RHEL / CentOS / Rocky / Alma | `libunwind-devel` |
| Debian / Ubuntu | `libunwind-dev` |
| Alpine | `libunwind-dev` |

The package **must provide the dynamic libraries**
(`libunwind.so`, `libunwind-ptrace.so`, `libunwind-<arch>.so`).

> ✅ **Installation rule (read this first)**: if, after installing
> the distro's `libunwind-devel` / `libunwind-dev` package,
> **`libunwind-ptrace.so` is still missing** from
> `/usr/lib64/` (or the equivalent multiarch directory), you
> **must build libunwind from source** into a private prefix and
> build the extension with `LIBUNWIND_PREFIX=<prefix>`.  This is
> not optional -- linking a non-PIC `libunwind-ptrace.a` into a
> `-shared` PostgreSQL module fails at link time.  See
> [Verify `libunwind-ptrace.so` is actually present](#verify-libunwind-ptraceso-is-actually-present)
> just below for the exact check and the source-build recipe.

### Verify `libunwind-ptrace.so` is actually present

Installing `libunwind-devel` (or `libunwind-dev`) is **not by
itself sufficient** -- on some distros the package ships headers
and a non-PIC `.a` but omits `libunwind-ptrace.so` entirely.
Before trying to build the extension, confirm the shared library
is really there:

```sh
# 1. The unversioned linker symlink that "ld -lunwind-ptrace" resolves.
ls -la /usr/lib64/libunwind-ptrace.so /usr/lib/x86_64-linux-gnu/libunwind-ptrace.so 2>/dev/null

# 2. Inspect what the -devel package actually ships.
rpm -ql libunwind-devel 2>/dev/null | grep libunwind-ptrace   # RPM-based
dpkg -L libunwind-dev    2>/dev/null | grep libunwind-ptrace  # Debian-based
```

**If `libunwind-ptrace.so` is missing from the output above --
even though `libunwind-devel` / `libunwind-dev` is installed --
you MUST build libunwind from source** (recipe below).
Installing or re-installing the distro `-devel` package will
**not** fix it; the package on that distro simply does not
contain the shared library.  This situation has been observed on:

* RHEL 7 / CentOS 7 / Oracle Linux 7 and their EPEL variants
  (`libunwind-devel-1.1-*.el7`, `1.2-*.el7`)
* Some downstream / enterprise rebuilds that ship only a
  non-PIC `/usr/lib64/libunwind-ptrace.a` and omit the
  corresponding `.so`
* A handful of early Amazon Linux 2 / AlmaLinux 8 minor releases

> ⚠️ A non-PIC `libunwind-ptrace.a` cannot be linked into a
> `-shared` PostgreSQL module and produces:
> ```
> relocation R_X86_64_PC32 against symbol `_UPT_reg_offset`
> can not be used when making a shared object; recompile with -fPIC
> ```
> The Makefile detects this case and aborts with a helpful
> message pointing back here.

#### Source-build recipe (mandatory when `libunwind-ptrace.so` is absent)

Upstream releases are published on GitHub
(`https://github.com/libunwind/libunwind/releases`).  Pick a
version matching your compiler:

| Host compiler | Recommended libunwind |
|---|---|
| GCC >= 4.9 (modern distros) | **1.8.1** (latest stable) |
| GCC 4.8 (RHEL/CentOS 7) | **1.5.0** (no `<stdatomic.h>`) |

```sh
# Modern systems: latest stable (requires GCC >= 4.9 for C11)
curl -LO https://github.com/libunwind/libunwind/releases/download/v1.8.1/libunwind-1.8.1.tar.gz
tar xzf libunwind-1.8.1.tar.gz && cd libunwind-1.8.1

# RHEL 7 / GCC 4.8 fallback:
# curl -LO https://github.com/libunwind/libunwind/releases/download/v1.5/libunwind-1.5.0.tar.gz
# tar xzf libunwind-1.5.0.tar.gz && cd libunwind-1.5.0

./configure --prefix=/opt/libunwind-pic \
            --enable-shared --enable-static \
            --enable-ptrace CFLAGS="-fPIC -O2"
make -j$(nproc) && sudo make install
```

Then pass `LIBUNWIND_PREFIX=/opt/libunwind-pic` to `make` when
building the extension (see [Using a private libunwind](#using-a-private-libunwind-libunwind_prefix)
below).  The resulting `pg_stat_backtrace.so` gets
`-Wl,-rpath` embedded automatically, so no `ldconfig` or
`LD_LIBRARY_PATH` is needed at runtime.

## Runtime requirements

* **Linux only.**  `ptrace(2)` semantics are Linux-specific and
  `/proc/<pid>/status` is read for UID re-verification.
* `kernel.yama.ptrace_scope` must be `0` or `1`.  Value `1`
  (Yama's "restricted ptrace") only permits attach to a
  **descendant** of the caller, or to a process that has opted
  the caller in via `prctl(PR_SET_PTRACER)`.  PostgreSQL backends
  are direct children of the postmaster but *sibling* processes
  with respect to each other, so a backend calling
  `pg_get_backtrace()` on another backend is neither an ancestor
  nor a descendant of its target and will be rejected by Yama
  under `ptrace_scope=1`.  On dedicated database hosts set it to
  `0`:
  ```sh
  echo 0 | sudo tee /proc/sys/kernel/yama/ptrace_scope
  # persist:
  echo 'kernel.yama.ptrace_scope = 0' | sudo tee /etc/sysctl.d/10-ptrace.conf
  ```
* The PostgreSQL server user must own (same UID as) the target.
  This is automatically true for processes managed by this
  instance's postmaster.

## Build and install

> 🛑 **Before you build: verify `libunwind-ptrace.so` exists.**
> Installing `libunwind-devel` / `libunwind-dev` is **not**
> guaranteed to provide the shared library -- some distros ship
> only a non-PIC static archive (see [Build dependencies](#build-dependencies)).
> Run this one-liner first:
> ```sh
> ls /usr/lib64/libunwind-ptrace.so \
>    /usr/lib/x86_64-linux-gnu/libunwind-ptrace.so \
>    /usr/lib/aarch64-linux-gnu/libunwind-ptrace.so 2>/dev/null
> ```
> **Decision rule:**
> * **File found** (in any of the paths above) → proceed with the
>   standard `make` below.
> * **No output at all** → the distro package is incomplete; you
>   **must build libunwind from source** into a private prefix
>   (see [Build dependencies › Verify `libunwind-ptrace.so`](#verify-libunwind-ptraceso-is-actually-present)),
>   then build the extension with `LIBUNWIND_PREFIX=...` as
>   described in [Using a private libunwind](#using-a-private-libunwind-libunwind_prefix)
>   below.  Re-installing `libunwind-devel` will not help.

Clone this repository and build against an installed PostgreSQL
server (the default, PGXS-based build):

```sh
git clone https://github.com/<you>/pg_stat_backtrace.git
cd pg_stat_backtrace
make              # auto-detects PGXS when not inside a PG source tree
sudo make install
```

If you have multiple PostgreSQL installations, point `PG_CONFIG`
at the one you want to build for:

```sh
make PG_CONFIG=/usr/pgsql-18/bin/pg_config
sudo make install PG_CONFIG=/usr/pgsql-18/bin/pg_config
```

> Building against an installed server requires the PostgreSQL
> **development package** (`postgresql-devel` /
> `postgresql-server-dev-*` / `postgresql<N>-devel`) -- it ships
> `pg_config` **and** the PGXS makefile fragment
> (`<libdir>/pgxs/src/makefiles/pgxs.mk`).  If you see
> `No such file or directory ... pgxs.mk`, install the devel
> package for your server's major version, e.g.
> `dnf install postgresql18-devel` or
> `apt install postgresql-server-dev-17`.

<details>
<summary>Alternative: build as a contrib module inside the PostgreSQL source tree</summary>

If you prefer to vendor the extension into a PostgreSQL source
tree and build it alongside the server itself:

```sh
cp -r pg_stat_backtrace /path/to/postgres/contrib/
cd /path/to/postgres/contrib/pg_stat_backtrace
make
sudo make install
```

The Makefile auto-detects that it is inside a PG source tree
(by locating `../../src/Makefile.global`) and switches from
PGXS to the in-tree build rules automatically.  The bundled
`meson.build` is also picked up by PostgreSQL's top-level
meson build in this layout.

</details>

### Using a private libunwind (LIBUNWIND_PREFIX)

If libunwind is installed in a non-standard location (typically
because you built a PIC version yourself to work around a
non-PIC distro package -- see "Build dependencies" above), point
the build at it with `LIBUNWIND_PREFIX`:

```sh
make LIBUNWIND_PREFIX=/opt/libunwind-pic
sudo make install LIBUNWIND_PREFIX=/opt/libunwind-pic
```

The Makefile will:
* prepend `$LIBUNWIND_PREFIX/lib/pkgconfig` (and `lib64/pkgconfig`)
  to `PKG_CONFIG_PATH` so pkg-config finds the private install;
* embed `-Wl,-rpath,$LIBUNWIND_PREFIX/lib` into the extension's
  `.so` so the dynamic linker finds `libunwind-ptrace.so.0` at
  load time **without** needing `ldconfig` or `LD_LIBRARY_PATH`.

Verify the rpath was embedded:
```sh
readelf -d $(pg_config --pkglibdir)/pg_stat_backtrace.so | grep -E 'RUNPATH|RPATH'
# Expected: RUNPATH contains /opt/libunwind-pic/lib
ldd $(pg_config --pkglibdir)/pg_stat_backtrace.so | grep libunwind
# Expected: all libunwind* resolve, none is "not found"
```

Then in psql:
```sql
CREATE EXTENSION pg_stat_backtrace;
```

## Examples

```sql
-- Find the pid of a stuck autovacuum worker.
SELECT pid, query, state, wait_event
FROM   pg_stat_activity
WHERE  backend_type = 'autovacuum worker';

-- Capture and view its backtrace as text.  Substitute the real
-- pid from pg_stat_activity above for 123456.
SELECT pg_get_backtrace(123456);

-- Or write it to the server log instead, where it'll get picked up
-- by your log-shipping pipeline.
SELECT pg_log_backtrace(123456);

-- Dump backtraces of all walsenders to the log in one go.
SELECT pid, pg_log_backtrace(pid)
FROM   pg_stat_activity
WHERE  backend_type = 'walsender';
```

## Authors

Capture path (`ptrace` + `libunwind`), permission model, signal-safety
analysis, and PG14 - PG19 compatibility shim were contributed as part
of this module.  Prior art that informed the design:

* PostgreSQL's in-core `pg_log_backend_memory_contexts()`
  (PG14+), which uses a signal-handler path to record *memory
  contexts* (not a C-level stack); this module deliberately
  avoids the signal-handler path to remain signal-free and
  records a real call stack instead.
* `pstack(1)` from elfutils/GDB, whose output format this module mimics.

## License

[PostgreSQL License](./LICENSE) -- same terms as PostgreSQL itself.
