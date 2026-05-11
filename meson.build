# contrib/pg_stat_backtrace/meson.build
#
# This file is ONLY used when pg_stat_backtrace is built in-tree from
# the PostgreSQL source tree via meson (i.e. dropped into
# $PG_SRC/contrib/pg_stat_backtrace/ and built with the top-level
# meson + ninja).
#
# When this repository is checked out as a standalone extension and
# built with the classic `make USE_PGXS=1` path (the default for
# users who clone the GitHub repo), meson is not invoked at all and
# this file is simply ignored -- see Makefile.
#
# Probe libunwind + libunwind-ptrace via pkg-config and refuse to
# build (rather than stub out) if either is missing.

# Guard against being loaded outside an in-tree PG build.  The
# symbols contrib_mod_args / contrib_data_args / contrib_targets /
# tests are defined by the top-level PostgreSQL meson setup; if
# they aren't visible we're being driven by some other build system
# and must bail out cleanly rather than error.
if not is_variable('contrib_mod_args')
  subdir_done()
endif

libunwind_dep        = dependency('libunwind',         required: false)
libunwind_ptrace_dep = dependency('libunwind-ptrace',  required: false)

if not libunwind_dep.found() or not libunwind_ptrace_dep.found()
  warning('pg_stat_backtrace disabled: libunwind/libunwind-ptrace not found')
  subdir_done()
endif

pg_stat_backtrace_sources = files(
  'pg_stat_backtrace.c',
)

if host_system == 'windows'
  pg_stat_backtrace_sources += rc_lib_gen.process(win32ver_rc, extra_args: [
    '--NAME', 'pg_stat_backtrace',
    '--FILEDESC', 'pg_stat_backtrace - get/log C-level backtrace via ptrace+libunwind',
  ])
endif

pg_stat_backtrace = shared_module('pg_stat_backtrace',
  pg_stat_backtrace_sources,
  kwargs: contrib_mod_args + {
    'dependencies': contrib_mod_args['dependencies'] + [
      libunwind_dep,
      libunwind_ptrace_dep,
    ],
  },
)
contrib_targets += pg_stat_backtrace

install_data(
  'pg_stat_backtrace.control',
  'pg_stat_backtrace--1.0.sql',
  kwargs: contrib_data_args,
)

tests += {
  'name': 'pg_stat_backtrace',
  'sd': meson.current_source_dir(),
  'bd': meson.current_build_dir(),
  'regress': {
    'sql': [
      'pg_stat_backtrace',
    ],
  },
  'tap': {
    'tests': [
      't/001_basic.pl',
      't/002_permission.pl',
      't/003_capture.pl',
      't/004_target_lifecycle.pl',
      't/005_concurrent.pl',
    ],
  },
}
