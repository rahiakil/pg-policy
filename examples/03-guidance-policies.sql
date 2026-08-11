-- Example 03: guidance / soft steering
CREATE EXTENSION IF NOT EXISTS pg_policy;

SELECT pg_policy.set_setting('enforcement_mode', 'enforce');

SELECT pg_policy.upsert_policy('prefer_explain', $apl$
guide
  principal agent "research_bot"
  action tool "execute_sql"
  advice "Run EXPLAIN before large analytical queries"
  prefer_tool "sql_explain"
  max_rows 500
$apl$, 'Steer SQL agents toward EXPLAIN + row caps', 50);

SELECT pg_policy.evaluate(
  'agent', 'research_bot', 'tool', 'execute_sql',
  '*', '*', '{"statement_type":"SELECT"}'::jsonb
);
-- => allowed=true with obligations: advice, prefer_tool, max_rows
