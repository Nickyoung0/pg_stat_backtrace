# Security Policy

## Threat model

`pg_stat_backtrace` calls `ptrace(2)` against another PostgreSQL
process running as the same OS user. Because `ptrace` is a privileged
operation that can read another process's memory and registers, the
extension enforces a defense-in-depth permission model:

1. **SQL-layer ACL**: install script `REVOKE EXECUTE ... FROM PUBLIC`,
   so only superusers (and any roles explicitly `GRANT`ed) can call
   the SQL functions at all.
2. **PostgreSQL role check**: mirrors `pg_signal_backend()` — a
   non-superuser may only target a regular backend owned by a role
   they are a *member of*, and that backend must not itself be a
   superuser session. Auxiliary processes have no role and are
   therefore rejected for non-superusers.
3. **OS-layer UID re-verification**: after `PTRACE_SEIZE` succeeds
   we re-read `/proc/<pid>/status` and abort if the target's UID
   does not equal `geteuid()`. This guards against PID reuse between
   the role check and the actual attach.
4. **Self-target rejection**: `pid == MyProcPid` is rejected up
   front; Linux refuses self-`ptrace` and we surface a clearer error.
5. **Postmaster rejection**: `ptrace`-ing PID 1 of the cluster
   would freeze the whole instance, so it is rejected explicitly.

## Reporting a vulnerability

If you discover a security issue, please **do not** open a public
GitHub issue. Instead, email the maintainers (see `README.md`) with:

- A description of the issue
- Steps to reproduce (a minimal SQL transcript is best)
- The PostgreSQL major version and Linux kernel version
- Whether you believe the issue is exploitable cross-account or only
  by an already-trusted role

You should expect an acknowledgement within 7 days. We will treat the
report as confidential until a fix is published, and we will credit
you in the `CHANGELOG.md` unless you prefer otherwise.

## Known limitations

- The OS-layer UID check requires `procfs` (`/proc`). On systems
  where `/proc` is not mounted, the extension fails closed.
- `kernel.yama.ptrace_scope = 3` (Linux YAMA "no attach") disables
  `ptrace` entirely; the extension cannot work in that environment.
- The extension does not currently support targets running under a
  different OS UID than the PostgreSQL backend (this is a Linux
  `ptrace` restriction, not a defect).
