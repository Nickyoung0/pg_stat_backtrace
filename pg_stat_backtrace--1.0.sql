/* contrib/pg_stat_backtrace/pg_stat_backtrace--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_stat_backtrace" to load this file. \quit

--
-- pg_get_backtrace(pid int) RETURNS text
--
--   Attach to the target PostgreSQL process with ptrace(2) (using
--   PTRACE_SEIZE + PTRACE_INTERRUPT, no SIGSTOP is sent), unwind its
--   stack with libunwind (DWARF CFI based) and return a pstack(1)-style
--   textual backtrace.  The target is briefly paused (typically
--   single-digit milliseconds) and resumed before the function returns.
--
--   Permission model (enforced inside the C code):
--     * superusers     : may target any PG process in this instance,
--                        including auxiliary processes (walwriter,
--                        checkpointer, bgwriter, walsender, autovacuum,
--                        startup, archiver, ...).
--     * non-superusers : may only target a regular backend that is
--                        owned by a role they have membership in
--                        (mirrors pg_signal_backend's policy).  Aux
--                        processes have no role attached and are
--                        always rejected for non-superusers.
--
--   Other safety checks:
--     * Self (pid = MyProcPid) is rejected: a process cannot ptrace
--       itself on Linux.  Use a separate session if you need it.
--     * Postmaster pid is rejected: stopping it would block new
--       connections.
--     * The target's real UID is re-verified after PTRACE_SEIZE to
--       close the narrow PID-reuse race window.
--
--   Returns NULL on invalid input; raises ERROR on permission failure
--   or ptrace/libunwind errors.
--
CREATE FUNCTION pg_get_backtrace(pid int)
RETURNS text
AS 'MODULE_PATHNAME', 'pg_get_backtrace'
LANGUAGE C VOLATILE STRICT PARALLEL RESTRICTED;

--
-- pg_log_backtrace(pid int) RETURNS boolean
--
--   Same capture mechanism as pg_get_backtrace(pid), but instead of
--   returning the backtrace as text it is written to the server log
--   at LOG level.  Returns true on success.
--
--   Useful for capturing stacks of background processes (walsender,
--   logical replication workers, autovacuum workers, ...) where you
--   don't have an interactive psql session to read the result, and
--   for forwarding the backtrace via the existing log pipeline (csv
--   logs, syslog, jsonlog, log shipping).
--
--   Same permission model and target-validation rules as
--   pg_get_backtrace(pid).
--
CREATE FUNCTION pg_log_backtrace(pid int)
RETURNS boolean
AS 'MODULE_PATHNAME', 'pg_log_backtrace'
LANGUAGE C VOLATILE STRICT PARALLEL RESTRICTED;

-- Restrict execution to superusers by default; site administrators
-- may GRANT EXECUTE to specific monitoring roles, in which case the
-- C code still enforces the role-membership check above.
REVOKE EXECUTE ON FUNCTION pg_get_backtrace(int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pg_log_backtrace(int) FROM PUBLIC;
