-- Pack: baseline (load first on every database)
-- Universal agent floor: no DDL/admin, steer SQL, cap bulk export.
-- Does not change enforcement_mode (stay log_only until you promote).

CREATE EXTENSION IF NOT EXISTS pg_agent_policy;

SELECT pg_agent_policy.upsert_policy('pack_baseline_ddl', $apl$
forbid
  principal agent "*"
  action tool "execute_sql"
  when { context.statement_type in ["DROP", "TRUNCATE", "ALTER", "CREATE", "GRANT", "REVOKE", "CLUSTER", "VACUUM"] }
  reason "Baseline: agents may not run DDL or privilege SQL"
$apl$, 'Baseline DDL/admin deny', 10);

SELECT pg_agent_policy.upsert_policy('pack_baseline_copy', $apl$
forbid
  principal agent "*"
  action tool "execute_sql"
  when { context.statement_type in ["COPY"] }
  reason "Baseline: COPY is an exfil/load path; use export tools with quotas"
$apl$, 'Baseline block COPY', 11);

SELECT pg_agent_policy.upsert_policy('pack_baseline_sql_guide', $apl$
guide
  principal agent "*"
  action tool "execute_sql"
  advice "Prefer explain_query for expensive scans; honor max_rows"
  prefer_tool "explain_query"
  max_rows 500
$apl$, 'Baseline SQL steering', 80);

SELECT pg_agent_policy.upsert_policy('pack_baseline_export_quota', $apl$
forbid
  principal agent "*"
  action tool "export_csv"
  when temporal {
    count(action == "export_csv") within interval '1 hour' >= 5
  }
  reason "Baseline: export budget exceeded (5/hour/session)"
$apl$, 'Baseline export quota', 20);

SELECT 'loaded pack baseline' AS pack;
