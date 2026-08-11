-- Pack: fintech / payments ops
-- PEP MUST send context.acting_for (human) and context.approved for money tools.
-- Use "unset" / "false" as fail-closed sentinels from middleware.

CREATE EXTENSION IF NOT EXISTS pg_policy;

SELECT pg_policy.upsert_policy('pack_fintech_need_actor', $apl$
forbid
  principal agent "*"
  action tool "execute_sql"
  when { context.acting_for == "unset" }
  reason "Fintech: acting_for (human user) required for attribution"
$apl$, 'Fintech: require acting_for on SQL', 5);

SELECT pg_policy.upsert_policy('pack_fintech_need_actor_transfer', $apl$
forbid
  principal agent "*"
  action tool "transfer_funds"
  when { context.acting_for == "unset" }
  reason "Fintech: transfers must be attributed to a human"
$apl$, 'Fintech: require acting_for on transfer', 5);

SELECT pg_policy.upsert_policy('pack_fintech_transfer_hitl', $apl$
forbid
  principal agent "*"
  action tool "transfer_funds"
  when { context.approved == "false" }
  reason "Fintech: transfer_funds requires human approval flag"
$apl$, 'Fintech: dual control on transfers', 6);

SELECT pg_policy.upsert_policy('pack_fintech_transfer_quota', $apl$
forbid
  principal agent "*"
  action tool "transfer_funds"
  when temporal {
    count(action == "transfer_funds") within interval '1 hour' >= 1
  }
  reason "Fintech: at most one transfer per hour per session without a new approval cycle"
$apl$, 'Fintech: transfer velocity', 7);

SELECT pg_policy.upsert_policy('pack_fintech_read', $apl$
permit
  principal agent "*"
  action tool "execute_sql"
  when { context.statement_type in ["SELECT"] }
  reason "Fintech: investigative SELECT permitted"
$apl$, 'Fintech: allow SELECT', 40);

SELECT pg_policy.upsert_policy('pack_fintech_guide', $apl$
guide
  principal agent "*"
  action tool "execute_sql"
  advice "Log the business reason in context.reason_code before any mutation tool"
  max_rows 100
$apl$, 'Fintech: investigation hygiene', 70);

SELECT 'loaded pack fintech' AS pack;
