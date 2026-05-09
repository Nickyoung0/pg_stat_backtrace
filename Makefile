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
# The package MUST provide the dynamic libraries:
#   libunwind.so, libunwind-ptrace.so, libunwind-<arch>.so
# A non-PIC libunwind-ptrace.a (as shipped by some RHEL-family distros)
# cannot be linked into a -shared module and is rejected.
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
# Detect the .so / .a situation explicitly so we produce a helpful error
# message on RHEL/CentOS where only the non-PIC .a is installed.
#
# We do TWO checks, in order:
#   1. Look for a *real* libunwind-ptrace.so in the usual library dirs.
#      A pkg-config --libs hit that resolves only to libunwind-ptrace.a
#      will later fail with the classic "R_X86_64_PC32 ... recompile with
#      -fPIC" link error from ld, which is exactly what we want to
#      pre-empt with a better message.
#   2. Try an actual PIC link of a trivial object against the pkg-config
#      flags.  This catches exotic layouts where the .so lives in an
#      unusual place but ld/ldconfig can find it anyway.
# ----------------------------------------------------------------------

PSBT_UNWIND_LIBDIR := $(shell $(PKG_CONFIG) --variable=libdir libunwind-ptrace 2>/dev/null)

# Resolve -L prefix hints from pkg-config --libs-only-L too; some distros
# point the dev package at an unusual directory.
PSBT_UNWIND_LIBDIRS := $(PSBT_UNWIND_LIBDIR) \
	$(patsubst -L%,%,$(filter -L%,$(PSBT_UNWIND_LIBS))) \
	/usr/lib64 /usr/lib \
	/usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu \
	/usr/local/lib64 /usr/local/lib

# Split the probe: we need BOTH
#   * a "linker symlink" (plain libunwind-ptrace.so without version suffix)
#     -- this is what "ld -lunwind-ptrace" actually resolves, and it is
#     only shipped by the -devel / -dev package; if it is missing, ld
#     silently falls back to the non-PIC .a in the same directory and
#     we get the R_X86_64_PC32 error later in the build.
#   * at least one versioned runtime .so.N* -- sanity check that the
#     shared library itself is actually installed.
#
# Both lists are computed so we can emit distinct diagnostics.
PSBT_UNWIND_PTRACE_SO_LINK := $(strip $(foreach d,$(PSBT_UNWIND_LIBDIRS),\
	$(wildcard $(d)/libunwind-ptrace.so)))
PSBT_UNWIND_PTRACE_SO_VERS := $(strip $(foreach d,$(PSBT_UNWIND_LIBDIRS),\
	$(wildcard $(d)/libunwind-ptrace.so.*)))

ifeq ($(PSBT_UNWIND_PTRACE_SO_LINK)$(PSBT_UNWIND_PTRACE_SO_VERS),)
$(error pg_stat_backtrace: no SHARED libunwind-ptrace.so was found in \
	any of $(PSBT_UNWIND_LIBDIRS).  Only the non-PIC static archive \
	libunwind-ptrace.a (if any) is present, which cannot be linked into \
	a PIC shared module.  Fixes: (1) install a libunwind-devel package \
	that ships .so files (EPEL on RHEL/CentOS), or (2) build libunwind \
	from source with "./configure --enable-shared --with-pic \
	--enable-ptrace" and re-run "make".)
endif

ifeq ($(PSBT_UNWIND_PTRACE_SO_LINK),)
$(error pg_stat_backtrace: versioned libunwind-ptrace.so.N was found \
	($(PSBT_UNWIND_PTRACE_SO_VERS)), but the unversioned linker symlink \
	'libunwind-ptrace.so' is missing.  This happens when only the \
	runtime libunwind package is installed, not the development \
	package.  In that situation "ld -lunwind-ptrace" silently falls \
	back to the non-PIC libunwind-ptrace.a and fails with \
	R_X86_64_PC32 relocation errors.  Fix: install the matching \
	-devel / -dev package, for example: \
	"dnf install libunwind-devel" (RHEL/Fedora), \
	"apt install libunwind-dev" (Debian/Ubuntu), or rebuild libunwind \
	from source with --enable-shared --with-pic --enable-ptrace.)
endif

# Belt-and-braces: try an actual PIC shared link.  If this fails, emit a
# synthesised "you hit the non-PIC .a" error BEFORE the real build starts,
# instead of letting ld surface the cryptic R_X86_64_PC32 message much
# later in the build.
PSBT_UNWIND_LINKTEST := $(shell \
	printf 'int main(void){return 0;}\n' > /tmp/psbt_linktest.c 2>/dev/null && \
	$(CC) -shared -fPIC /tmp/psbt_linktest.c -o /tmp/psbt_linktest.so \
		$(PSBT_UNWIND_LIBS) 2>&1; \
	rc=$$?; rm -f /tmp/psbt_linktest.c /tmp/psbt_linktest.so; \
	if [ $$rc -ne 0 ]; then echo FAIL; fi)

ifneq (,$(findstring FAIL,$(PSBT_UNWIND_LINKTEST)))
$(error pg_stat_backtrace: a trial PIC link against libunwind-ptrace \
	failed.  This almost always means the installed libunwind-ptrace.a \
	was built without -fPIC and cannot be linked into a PostgreSQL \
	shared module.  Fix: install a libunwind package that provides \
	libunwind-ptrace.so (EPEL on RHEL/CentOS), or rebuild libunwind \
	from source with "--enable-shared --with-pic --enable-ptrace".)
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
