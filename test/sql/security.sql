-- v0.2 security hardening tests
-- Append-only audit, identity binding, session minting,
-- atomic temporal semantics, and hash chain.

-- Self-isolate: drop any prior install so this test is order-independent.
DROP EXTENSION IF EXISTS pg_agent_policy CASCADE;
CREATE EXTENSION pg_agent_policy;

-- A non-privileged agent role: append-only audit is enforced via
-- GRANT/REVOKE, which superusers bypass. We run the tamper attempts
-- below as this role so insufficient_privilege actually fires.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'agent_app') THEN
    CREATE ROLE agent_app NOLOGIN;
  END IF;
END $$;
GRANT USAGE ON SCHEMA agent_policy TO agent_app;
-- INSERT is granted to PUBLIC by the extension; ensure SELECT for verification.
GRANT SELECT ON agent_policy.decision_log TO agent_app;

SELECT agent_policy.set_setting('enforcement_mode', 'enforce');

-- 1. Append-only audit -----------------------------------------------------
SELECT agent_policy.upsert_policy('block_ddl', $apl$
forbid
  principal agent "bot"
  action tool "execute_sql"
  when { context.statement_type in ["DROP"] }
  reason "no ddl"
$apl$);

-- Insert a decision log row via evaluate (allowed path)
SELECT agent_policy.evaluate(
  'agent','bot','tool','execute_sql','*','*',
  '{"statement_type":"DROP"}'::jsonb
)->>'decision' AS drop_decision;

-- Verify the row exists and has a hash chain
SELECT row_hash IS NOT NULL AS has_hash,
       policy_version IS NOT NULL AS has_version
FROM agent_policy.decision_log
ORDER BY log_id DESC
LIMIT 1;

-- Attempt to DELETE should fail (append-only) as a non-superuser.
\set VERBOSITY terse
-- Shadow mode for this section: we are testing the SQL-level REVOKE
-- (append-only), not the C hook. With the hook in shadow mode the
-- statement proceeds to the REVOKE, which raises insufficient_privilege.
SET pg_agent_policy.hook_log_only = true;
SET SESSION AUTHORIZATION agent_app;
DO $$
BEGIN
  DELETE FROM agent_policy.decision_log WHERE log_id = 1;
  RAISE NOTICE 'delete_succeeded';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'delete_blocked';
END $$;

-- Attempt to UPDATE should fail (append-only) as a non-superuser.
DO $$
BEGIN
  UPDATE agent_policy.decision_log SET decision = 'allow' WHERE log_id = 1;
  RAISE NOTICE 'update_succeeded';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'update_blocked';
END $$;
RESET SESSION AUTHORIZATION;
SET pg_agent_policy.hook_log_only = false;

-- 2. Server-side session minting ------------------------------------------
SELECT agent_policy.mint_session_id() ~ '^sess_[0-9a-f]{64}$' AS minted_id_format;

-- open_session_minted does not accept a caller-supplied session id
SELECT agent_policy.open_session_minted('agent', 'bot', '{}'::jsonb) ~ '^sess_' AS minted_session;

-- 3. Identity binding -----------------------------------------------------
SELECT agent_policy.get_current_principal() IS NULL AS principal_unbound;
SELECT agent_policy.get_current_session() IS NULL AS session_unset_by_default;

-- 4. Atomic temporal semantics -------------------------------------------
SELECT agent_policy.upsert_policy('export_quota', $apl$
forbid
  principal agent "bot"
  action tool "export_csv"
  when temporal {
    count(action == "export_csv") within interval '1 hour' >= 2
  }
  reason "export budget"
$apl$);

-- Permit export_csv by default; the forbid above (deny-overrides) kicks in
-- once the per-hour budget is exhausted.
SELECT agent_policy.upsert_policy('permit_export', $apl$
permit
  principal agent "bot"
  action tool "export_csv"
$apl$);

-- Open a minted session for the temporal test
SELECT agent_policy.open_session_minted('agent', 'bot', '{}'::jsonb) AS sid \gset

-- First export: allowed (count 0 < 2)
SELECT agent_policy.evaluate_atomic(
  'agent','bot','tool','export_csv','*','*','{}'::jsonb,
  :'sid', false
)->>'decision' AS first_export;

-- Second export: allowed (count 1 < 2)
SELECT agent_policy.evaluate_atomic(
  'agent','bot','tool','export_csv','*','*','{}'::jsonb,
  :'sid', false
)->>'decision' AS second_export;

-- Third export: denied (count 2 >= 2)
SELECT agent_policy.evaluate_atomic(
  'agent','bot','tool','export_csv','*','*','{}'::jsonb,
  :'sid', false
)->>'decision' AS third_export;

-- 5. Hash chain verification --------------------------------------------
SELECT count(*) AS total_rows,
       count(*) FILTER (WHERE row_hash IS NOT NULL) AS hashed_rows,
       count(*) FILTER (WHERE prev_hash IS NOT NULL) AS chained_rows
FROM agent_policy.decision_log;
