-- Example 02: session temporal limits
CREATE EXTENSION IF NOT EXISTS pg_agent_policy;

SELECT pg_agent_policy.set_setting('enforcement_mode', 'enforce');

SELECT pg_agent_policy.open_session('sess-export-demo', 'agent', 'research_bot');

SELECT pg_agent_policy.upsert_policy('export_budget', $apl$
forbid
  principal agent "research_bot"
  action tool "export_csv"
  when temporal {
    count(action == "export_csv") within interval '1 hour' >= 3
  }
  reason "Export budget exceeded (max 3/hour)"
$apl$, 'Rate-limit CSV export', 10);

-- First three exports allowed (no temporal match yet / under threshold)
SELECT pg_agent_policy.evaluate('agent','research_bot','tool','export_csv','*','*','{}'::jsonb,'sess-export-demo');
SELECT pg_agent_policy.evaluate('agent','research_bot','tool','export_csv','*','*','{}'::jsonb,'sess-export-demo');
SELECT pg_agent_policy.evaluate('agent','research_bot','tool','export_csv','*','*','{}'::jsonb,'sess-export-demo');

-- Fourth should deny once count >= 3 from prior events
SELECT pg_agent_policy.evaluate('agent','research_bot','tool','export_csv','*','*','{}'::jsonb,'sess-export-demo');
