# contrib/pg_stat_backtrace/Makefile

MODULE_big = pg_stat_backtrace
OBJS = \
	$(WIN32RES) \
	pg_stat_backtrace.o

EXTENSION = pg_stat_backtrace
DATA = pg_stat_backtrace--1.0.sql
PGFILEDESC = "pg_stat_backtrace - get/log C-level backtrace via ptrace+libunwind"

# Regression tests (run via "make installcheck").  We only test
# platform-independent metadata (function existence, signatures,
# permission model, argument validation) -- the actual unwind output
# depends on architecture, optimization, debug info and yama
# ptrace_scope, and is therefore not asserted in regress.
REGRESS = pg_stat_backtrace

# TAP tests (run via "make check PROVE_TESTS=..." or "make check-world").
# These exercise end-to-end capture paths, including actual ptrace
# attach.  Tests that require ptrace permission self-skip when
# kernel.yama.ptrace_scope > 1 so they're safe in locked-down CI.
TAP_TESTS = 1

# ----------------------------------------------------------------------
# Mandatory dependency: libunwind + libunwind-ptrace.
#
# Every entry point uses ptrace + libunwind, so libunwind-ptrace.so
# is required -- if it isn't found at build time we abort rather than
# ship a stub.
#
# Build dependencies:
#   RHEL/CentOS:            yum install libunwind-devel
#   Debian/Ubuntu:          apt install libunwind-dev
#   Alpine:                 apk add libunwind-dev
#
# The libunwind development package must support linking the required
# ptrace functions into a shared module.
#
# Runtime requirements (target host):
#   - Linux only.  ptrace semantics are Linux-specific, and we read
#     /proc/<pid>/status for the post-attach UID re-check.
#   - kernel.yama.ptrace_scope in {0, 1}; value 1 requires the
#     parent/child relationship which sibling backends under the
#     postmaster do not have, so 0 is recommended on dedicated DB hosts.
#   - Caller and target must run as the same UID.
# ----------------------------------------------------------------------

PKG_CONFIG ?= pkg-config

# ----------------------------------------------------------------------
# Optional: LIBUNWIND_PREFIX
#   Point to a libunwind installation outside the default search path
#   (e.g. a locally built PIC version for distros that only ship a
#   non-PIC libunwind-ptrace.a).  When set we:
#     * prepend $LIBUNWIND_PREFIX/lib/pkgconfig to PKG_CONFIG_PATH;
#     * add -Wl,-rpath so the .so finds libunwind-ptrace at load time
#       without needing ldconfig or LD_LIBRARY_PATH.
# ----------------------------------------------------------------------
ifneq ($(LIBUNWIND_PREFIX),)
export PKG_CONFIG_PATH := $(LIBUNWIND_PREFIX)/lib/pkgconfig:$(LIBUNWIND_PREFIX)/lib64/pkgconfig:$(PKG_CONFIG_PATH)
PSBT_UNWIND_RPATH := -Wl,-rpath,$(LIBUNWIND_PREFIX)/lib
endif

# Probe pkg-config for libunwind + libunwind-ptrace.  The arch-specific
# backend (libunwind-<arch>) is pulled in transitively.
PSBT_UNWIND_CFLAGS := $(shell $(PKG_CONFIG) --cflags libunwind-ptrace libunwind 2>/dev/null)
PSBT_UNWIND_LIBS   := $(shell $(PKG_CONFIG) --libs   libunwind-ptrace libunwind 2>/dev/null)

ifeq ($(PSBT_UNWIND_LIBS),)
$(error pg_stat_backtrace requires libunwind + libunwind-ptrace, \
	but pkg-config could not find them.  Install libunwind-devel \
	(RHEL/CentOS) or libunwind-dev (Debian/Ubuntu) and ensure \
	pkg-config can see them.)
endif

# ----------------------------------------------------------------------
# Check the same symbols and linker flags used by the extension. Some
# distributions provide libunwind-ptrace as a linkable static archive.
PSBT_UNWIND_LINKTEST := $(shell \
	tmp=$$(mktemp -d) || exit 1; \
	trap 'rm -rf "$$tmp"' EXIT; \
	$(CC) $(CPPFLAGS) $(CFLAGS) $(PSBT_UNWIND_CFLAGS) -fPIC -shared \
		$(LDFLAGS) $(PG_LDFLAGS) -Wl,-z,defs \
		$(dir $(lastword $(MAKEFILE_LIST)))config/check_unwind.c \
		-o "$$tmp/probe.so" $(PSBT_UNWIND_LIBS) $(PSBT_UNWIND_RPATH) \
		>/dev/null && echo yes)

ifneq ($(PSBT_UNWIND_LINKTEST),yes)
$(error pg_stat_backtrace: cannot link the required libunwind-ptrace symbols into a shared module with the selected compiler and flags)
endif

PG_CPPFLAGS += $(PSBT_UNWIND_CFLAGS)
SHLIB_LINK  += $(PSBT_UNWIND_LIBS) $(PSBT_UNWIND_RPATH)

# ----------------------------------------------------------------------
# Build mode selection.
#
# Two supported layouts, selected automatically:
#
#   1. In-tree:   this Makefile lives at  $PG_SRC/contrib/pg_stat_backtrace/
#                 i.e. dropped into a PostgreSQL source tree.  We detect
#                 this by the presence of ../../src/Makefile.global and
#                 use the PG build system directly (no pg_config needed,
#                 the server isn't installed yet).
#
#   2. Standalone (PGXS):  this Makefile lives in its own git checkout
#                 somewhere outside the PG source tree, built against an
#                 already-installed PostgreSQL server.  This is the
#                 default path for users who `git clone` the extension
#                 repo.  Requires the PG devel package (postgresql-devel
#                 / postgresql-server-dev-*) so that pg_config + pgxs.mk
#                 are available.
#
# USE_PGXS=1 forces PGXS mode explicitly, overriding auto-detection.
# ----------------------------------------------------------------------

ifndef USE_PGXS
  ifeq ($(wildcard ../../src/Makefile.global),)
    # Not inside a PG source tree -> default to PGXS.
    USE_PGXS := 1
  endif
endif

ifdef USE_PGXS
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_stat_backtrace
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
