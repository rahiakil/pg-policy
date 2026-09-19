-- v0.2 C-level hook enforcement (ProcessUtility_hook + ExecutorStart_hook)
-- Proves the hook is non-bypassable AND fail-closed:
--   * a connection that never calls evaluate() still hits the referee;
--   * a non-superuser connection with NO bound principal is BLOCKED
--     (fail-closed), not allowed -- this is the primary threat (actor
--     class 2: a leaked DSN with no trusted PEP to set the GUC);
--   * a bound non-superuser connection is enforced against policy;
--   * superusers bypass (out of scope) and can manage the extension.

DROP EXTENSION IF EXISTS pg_agent_policy CASCADE;
CREATE EXTENSION pg_agent_policy;

SELECT agent_policy.set_setting('enforcement_mode', 'enforce');
SELECT agent_policy.upsert_policy('block_ddl', $apl$
forbid
  principal agent "bot"
  action tool "execute_sql"
  when { context.statement_type in ["DROP","CREATE","ALTER","TRUNCATE"] }
  reason "no ddl for agents"
$apl$);

-- Test roles (non-superuser agents).
CREATE ROLE agent_bot;
CREATE ROLE agent_noprin;
GRANT CREATE ON SCHEMA public TO agent_bot;
GRANT CREATE ON SCHEMA public TO agent_noprin;
-- A bound agent calls evaluate() (via the hook), so it needs USAGE on the
-- extension schema. This is a deployment grant the DBA gives agent roles.
GRANT USAGE ON SCHEMA agent_policy TO agent_bot;

-- 1. Superuser, no principal GUC: DDL is allowed (superusers out of scope).
CREATE TABLE admin_ok (id int);
DROP TABLE admin_ok;

-- 2. Superuser binds principal='bot': CREATE is blocked by the hook.
SET pg_agent_policy.principal_id = 'bot';
CREATE TABLE agent_blocked (id int);
-- SET/RESET is infrastructure: not enforced, so the gateway can unbind.
RESET pg_agent_policy.principal_id;

-- 3. Shadow mode: hook logs denials but does not block.
SET pg_agent_policy.hook_log_only = true;
SET pg_agent_policy.principal_id = 'bot';
CREATE TABLE shadow_ok (id int);
RESET pg_agent_policy.principal_id;
SET pg_agent_policy.hook_log_only = false;

-- 4. Fail-closed: a non-superuser with NO bound principal is BLOCKED.
RESET pg_agent_policy.principal_id;
SET SESSION AUTHORIZATION agent_noprin;
CREATE TABLE fail_closed (id int);
RESET SESSION AUTHORIZATION;

-- 5. Bound non-superuser is enforced: superuser bound principal='bot'
--    (simulating a PEP that binds identity then drops privileges), then
--    SET SESSION AUTHORIZATION drops to the non-superuser agent role. The
--    GUC persists, so the hook evaluates as principal='bot' and blocks.
SET pg_agent_policy.principal_id = 'bot';
SET SESSION AUTHORIZATION agent_bot;
CREATE TABLE bot_blocked (id int);
RESET SESSION AUTHORIZATION;
RESET pg_agent_policy.principal_id;

-- 6. Back to superuser: admin DDL works again.
CREATE TABLE admin_ok2 (id int);
DROP TABLE admin_ok2;

-- Cleanup.
REVOKE CREATE ON SCHEMA public FROM agent_bot, agent_noprin;
REVOKE USAGE ON SCHEMA agent_policy FROM agent_bot;
DROP ROLE agent_bot;
DROP ROLE agent_noprin;
