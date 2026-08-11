-- Pack: analytics / text-to-SQL BI copilot
-- Pair with RLS on tenant_id and a read-only agent_runtime role.

CREATE EXTENSION IF NOT EXISTS pg_policy;

SELECT pg_policy.upsert_policy('pack_analytics_writes', $apl$
forbid
  principal agent "*"
  action tool "execute_sql"
  when { context.statement_type in ["INSERT", "UPDATE", "DELETE", "MERGE"] }
  reason "Analytics agents are read-only"
$apl$, 'Analytics: no DML', 15);

SELECT pg_policy.upsert_policy('pack_analytics_need_tenant', $apl$
forbid
  principal agent "*"
  action tool "execute_sql"
  when { context.tenant_id == "unset" }
  reason "Analytics: tenant_id must be set in context (PEP fail-closed)"
$apl$, 'Analytics: require tenant context', 12);

SELECT pg_policy.upsert_policy('pack_analytics_select_ok', $apl$
permit
  principal agent "*"
  action tool "execute_sql"
  when { context.statement_type in ["SELECT"] }
  reason "Analytics: SELECT permitted"
$apl$, 'Analytics: allow SELECT', 40);

SELECT pg_policy.upsert_policy('pack_analytics_explain_ok', $apl$
permit
  principal agent "*"
  action tool "explain_query"
  reason "Analytics: EXPLAIN is encouraged"
$apl$, 'Analytics: allow EXPLAIN', 40);

SELECT pg_policy.upsert_policy('pack_analytics_list_ok', $apl$
permit
  principal agent "*"
  action tool "list_tables"
  reason "Analytics: schema discovery allowed"
$apl$, 'Analytics: allow list_tables', 40);

SELECT pg_policy.upsert_policy('pack_analytics_tight_rows', $apl$
guide
  principal agent "*"
  action tool "execute_sql"
  advice "BI copilots should aggregate, not dump fact tables"
  max_rows 200
$apl$, 'Analytics: tighter row cap', 70);

SELECT 'loaded pack analytics' AS pack;
