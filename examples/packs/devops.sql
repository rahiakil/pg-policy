-- Pack: DevOps / DBA / IDE coding agents
-- EXPLAIN and stats yes; live DDL no. Propose migrations as code, not as agent SQL.

CREATE EXTENSION IF NOT EXISTS pg_policy;

SELECT pg_policy.upsert_policy('pack_devops_live_ddl', $apl$
forbid
  principal agent "*"
  action tool "execute_sql"
  when { context.statement_type in ["DROP", "TRUNCATE", "ALTER", "CREATE", "REINDEX", "GRANT", "REVOKE"] }
  reason "DevOps agents must not apply live DDL; open a migration PR"
$apl$, 'DevOps: no live DDL', 10);

SELECT pg_policy.upsert_policy('pack_devops_writes', $apl$
forbid
  principal agent "*"
  action tool "execute_sql"
  when { context.statement_type in ["INSERT", "UPDATE", "DELETE", "MERGE"] }
  reason "DevOps pack default is non-mutating; use a dedicated writer role+pack to opt in"
$apl$, 'DevOps: no DML by default', 15);

SELECT pg_policy.upsert_policy('pack_devops_explain', $apl$
permit
  principal agent "*"
  action tool "explain_query"
  reason "DevOps: EXPLAIN is the primary tool"
$apl$, 'DevOps: allow EXPLAIN', 40);

SELECT pg_policy.upsert_policy('pack_devops_select', $apl$
permit
  principal agent "*"
  action tool "execute_sql"
  when { context.statement_type in ["SELECT"] }
  reason "DevOps: diagnostic SELECT"
$apl$, 'DevOps: allow SELECT', 40);

SELECT pg_policy.upsert_policy('pack_devops_guide', $apl$
guide
  principal agent "*"
  action tool "execute_sql"
  advice "Use explain_query first; never vacuum/full in agent sessions"
  prefer_tool "explain_query"
  max_rows 100
$apl$, 'DevOps: prefer EXPLAIN', 70);

SELECT 'loaded pack devops' AS pack;
