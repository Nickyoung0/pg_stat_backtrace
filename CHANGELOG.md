# Changelog

All notable changes to `pg_stat_backtrace` will be documented in this
file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
