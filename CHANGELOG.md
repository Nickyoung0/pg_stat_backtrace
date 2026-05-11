# Changelog

All notable changes to `pg_stat_backtrace` will be documented in this
file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- TAP tests `t/003_capture.pl`, `t/004_target_lifecycle.pl`,
  `t/005_concurrent.pl`: the helper `spawn_sleeper()` originally
  used `BackgroundPsql` and fed the long-running query directly
  into `$bg->{stdin}` without explicitly pumping IPC::Run.  The
  preamble call `$bg->query_until(qr/./, "SELECT 'ready'")` also
  passed a SQL string with no terminating newline / semicolon,
  which means `psql` never actually executed it — the test then
  blocked for the full 180 s default timeout.  Reworked these
  three files to fork an opaque `psql -c 'SELECT pg_sleep(N)'`
  child process (with `POSIX::setsid()` to detach from the
  parent's process group), which is portable across PG14-19
  `BackgroundPsql` interface differences and avoids any IPC::Run
  pump issues.  Also: replaced `kill 9, $backend_pid` in
  `004_target_lifecycle.pl` test 2 with `pg_terminate_backend()`,
  because `Cluster.pm` defaults `restart_after_crash=off` and any
  backend SIGKILL would shut down the whole test cluster.
  Verified passing on PG14, 15, 16, 17, 18, and 19.  No change to
  the extension itself; only the tests were wrong.

- TAP test `t/001_basic.pl`: the function-signature concatenation
  query was not portable across PG14-19.  `pronargs` is `int2` and
  `provolatile`/`proparallel` are of the internal `"char"` type;
  on PG18+ the parser refuses `text || "char"` with
  `ERROR: operator is not unique`, while `proisstrict::text`
  produces `'true'/'false'` (not the documented `'t'/'f'`).
  Added explicit `::text` casts and a `CASE` expression for the
  bool column.  Verified passing on PG14, 15, 16, 17, 18, and 19.
  No change to the extension itself; only the test was wrong.

## [1.0.0] - 2026-05-09

Initial public release.

### Added

- `pg_get_backtrace(pid int) RETURNS text` — capture and return the
  C-level stack of any PostgreSQL process on the same host.
- `pg_log_backtrace(pid int) RETURNS boolean` — write the captured
  backtrace to the server log at `LOG` level.
- Linux `ptrace(PTRACE_SEIZE) + PTRACE_INTERRUPT` capture path
  (no `SIGSTOP` is ever sent to the target).
- `libunwind` (DWARF CFI) symbolization via the `libunwind-ptrace`
  UPT accessors.
- Permission model that mirrors `pg_signal_backend`:
  superusers may target any process; non-superusers may only target
  regular backends owned by a role they are a member of.
- Default `REVOKE EXECUTE ... FROM PUBLIC` install policy.
- Defense in depth: ProcArray atomic snapshot of `roleId` under
  `LWLock(ProcArrayLock, LW_SHARED)`, `/proc/<pid>/status` UID
  re-verification after `PTRACE_SEIZE`, and `errno` preservation
  across `ereport()` boundaries.
- PGXS Makefile and Meson build (PG16+).
- Regression test (`pg_regress`) asserting only platform-independent
  properties.

### Tested on

PostgreSQL 14, 15, 16, 17, 18, 19 (devel) on x86_64 Linux.
