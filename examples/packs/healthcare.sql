-- Pack: healthcare / PHI assistant
-- Pair with RLS on patient panels. Never allow bulk export tools.
-- PEP MUST send context.acting_for (clinician) — use "unset" if missing.

CREATE EXTENSION IF NOT EXISTS pg_agent_policy;

SELECT pg_agent_policy.upsert_policy('pack_health_need_actor', $apl$
forbid
  principal agent "*"
  action tool "*"
  when { context.acting_for == "unset" }
  reason "HIPAA-oriented: unique human attribution required on every tool call"
$apl$, 'Healthcare: acting_for on all tools', 5);

SELECT pg_agent_policy.upsert_policy('pack_health_no_export', $apl$
forbid
  principal agent "*"
  action tool "export_csv"
  reason "Healthcare: bulk PHI export is forbidden"
$apl$, 'Healthcare: ban CSV export', 6);

SELECT pg_agent_policy.upsert_policy('pack_health_no_copy', $apl$
forbid
  principal agent "*"
  action tool "execute_sql"
  when { context.statement_type in ["COPY"] }
  reason "Healthcare: COPY is a PHI exfil path"
$apl$, 'Healthcare: ban COPY', 6);

SELECT pg_agent_policy.upsert_policy('pack_health_read', $apl$
permit
  principal agent "*"
  action tool "execute_sql"
  when { context.statement_type in ["SELECT"] }
  reason "Healthcare: minimum-necessary SELECT"
$apl$, 'Healthcare: allow SELECT', 40);

SELECT pg_agent_policy.upsert_policy('pack_health_min_nec', $apl$
guide
  principal agent "*"
  action tool "execute_sql"
  advice "Select encounter-scoped columns only; do not dump full patient graphs"
  max_rows 25
$apl$, 'Healthcare: minimum necessary row cap', 70);

SELECT 'loaded pack healthcare' AS pack;
