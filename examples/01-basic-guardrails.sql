-- Example 01: basic guardrails
CREATE EXTENSION IF NOT EXISTS pg_policy;

SELECT pg_policy.set_setting('enforcement_mode', 'enforce');

SELECT pg_policy.upsert_policy('block_ddl', $apl$
forbid
  principal agent "research_bot"
  action tool "execute_sql"
  when { context.statement_type in ["DROP", "TRUNCATE", "ALTER", "CREATE"] }
  reason "Research agents may not run DDL"
$apl$, 'Block DDL for research agents', 10);

SELECT pg_policy.upsert_policy('allow_select', $apl$
permit
  principal agent "research_bot"
  action tool "execute_sql"
  when { context.statement_type in ["SELECT"] }
  reason "Read-only SQL is permitted"
$apl$, 'Allow SELECT', 20);

-- Denied
SELECT pg_policy.evaluate(
  'agent', 'research_bot', 'tool', 'execute_sql',
  '*', '*', '{"statement_type":"DROP"}'::jsonb
);

-- Allowed
SELECT pg_policy.evaluate(
  'agent', 'research_bot', 'tool', 'execute_sql',
  '*', '*', '{"statement_type":"SELECT"}'::jsonb
);
