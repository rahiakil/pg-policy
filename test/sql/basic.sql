-- basic regression input for pg_policy
CREATE EXTENSION pg_policy;

SELECT pg_policy.set_setting('enforcement_mode', 'enforce');

SELECT pg_policy.upsert_policy('block_ddl', $apl$
forbid
  principal agent "bot"
  action tool "execute_sql"
  when { context.statement_type in ["DROP", "ALTER"] }
  reason "no ddl"
$apl$);

SELECT (pg_policy.evaluate(
  'agent','bot','tool','execute_sql','*','*',
  '{"statement_type":"DROP"}'::jsonb
)->>'decision') AS drop_decision;

SELECT (pg_policy.evaluate(
  'agent','bot','tool','execute_sql','*','*',
  '{"statement_type":"SELECT"}'::jsonb
)->>'decision') AS select_decision;

SELECT pg_policy.upsert_policy('guide_sql', $apl$
guide
  principal agent "bot"
  action tool "execute_sql"
  advice "prefer explain"
  max_rows 100
$apl$);

SELECT pg_policy.evaluate(
  'agent','bot','tool','execute_sql','*','*',
  '{"statement_type":"SELECT"}'::jsonb
)->'obligations' AS obligations;
