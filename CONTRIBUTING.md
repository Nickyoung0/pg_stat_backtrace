# Contributing to pg_stat_backtrace

Thank you for your interest in `pg_stat_backtrace`! Contributions are
welcome via GitHub issues and pull requests.

## Reporting issues

When filing a bug, please include:

- PostgreSQL version (`SELECT version();`)
- Linux kernel version (`uname -a`)
- libunwind version (`pkg-config --modversion libunwind libunwind-ptrace`)
- Value of `/proc/sys/kernel/yama/ptrace_scope`
- Steps to reproduce, including the exact SQL you ran
- Server log excerpt (with `log_min_messages = debug1` if relevant)
- Output of `SELECT pg_get_backtrace(pg_backend_pid())` from a *second*
  session (not the one being debugged)

## Building from source

```bash
# system dependencies (RHEL / CentOS / TencentOS)
sudo dnf install -y postgresqlNN-devel libunwind-devel
# or build PIC libunwind from source: see README.md

cd pg_stat_backtrace
make
sudo make install
make installcheck    # requires a running PG instance
```

See `README.md` for detailed build instructions and the `LIBUNWIND_PREFIX`
override for non-standard libunwind installs.

## Code style

This module follows the [PostgreSQL coding conventions]:

- 4-space tab indentation (configure your editor to match `pgindent`)
- Brace placement: opening brace on its own line for functions, on the
  same line for control statements
- Error reporting via `ereport()` / `elog()`, not `printf`
- Memory via `palloc()` / `pfree()` (or `MemoryContext`s); no `malloc`
- All system calls that touch `errno` must save/restore it across
  `ereport()` boundaries
- `volatile` for any local read inside a `PG_CATCH` arm
- No global mutable state; no signal handlers; no GUCs unless absolutely
  necessary

[PostgreSQL coding conventions]: https://www.postgresql.org/docs/current/source.html

## Pull request checklist

Before opening a PR:

- [ ] `make` succeeds with `-Wall -Wextra` and no new warnings
- [ ] `make installcheck` passes
- [ ] Tested on at least one of PG14, 16, 18 (PG18 strongly preferred)
- [ ] Updated `README.md` and/or `DESIGN.md` if behavior changed
- [ ] Updated `CHANGELOG.md` under an `[Unreleased]` heading
- [ ] No new `WARNING`s with `-fanalyzer` (GCC) or `--analyze` (clang)
- [ ] Code is `pgindent`ed

## Security issues

See `SECURITY.md`.

## License

By contributing, you agree that your contributions will be licensed
under the PostgreSQL License (see `LICENSE`).
