-- Example 05: MCP Postgres tool pack (starter)
-- Aligns action ids with common MCP tools: execute_sql, explain_query, list_tables, …
CREATE EXTENSION IF NOT EXISTS pg_agent_policy;

SELECT pg_agent_policy.set_setting('enforcement_mode', 'log_only');

SELECT pg_agent_policy.upsert_policy('mcp_block_ddl', $apl$
forbid
  principal agent "*"
  action tool "execute_sql"
  when { context.statement_type in ["DROP", "TRUNCATE", "ALTER", "CREATE", "GRANT", "REVOKE", "COPY"] }
  reason "MCP agents must not run DDL/admin SQL"
$apl$, 'MCP DDL firewall', 10);

SELECT pg_agent_policy.upsert_policy('mcp_row_cap_guidance', $apl$
guide
  principal agent "*"
  action tool "execute_sql"
  advice "Inject LIMIT / respect max_rows before returning to the model"
  prefer_tool "explain_query"
  max_rows 500
$apl$, 'MCP row cap + prefer EXPLAIN', 50);

SELECT pg_agent_policy.upsert_policy('mcp_export_budget', $apl$
forbid
  principal agent "*"
  action tool "export_csv"
  when temporal {
    count(action == "export_csv") within interval '1 hour' >= 5
  }
  reason "MCP export budget exceeded"
$apl$, 'MCP export rate limit', 20);

-- Shadow-mode evaluation sample
SELECT pg_agent_policy.open_session('mcp-sess-1', 'agent', 'cursor_agent');
SELECT pg_agent_policy.evaluate(
  'agent', 'cursor_agent', 'tool', 'execute_sql',
  '*', '*', '{"statement_type":"DROP"}'::jsonb, 'mcp-sess-1'
);
