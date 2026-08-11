-- Pack: customer-support copilot
-- Read tickets/orders; block PII export without approval; cap refunds.

CREATE EXTENSION IF NOT EXISTS pg_policy;

SELECT pg_policy.upsert_policy('pack_support_pii_export', $apl$
forbid
  principal agent "*"
  action tool "export_csv"
  when { context.approved == "false" }
  reason "Support: CSV export requires context.approved=true"
$apl$, 'Support: export needs approval', 15);

SELECT pg_policy.upsert_policy('pack_support_refund_quota', $apl$
forbid
  principal agent "*"
  action tool "refund"
  when temporal {
    count(action == "refund") within interval '24 hours' >= 3
  }
  reason "Support: refund quota exceeded (3/day/session)"
$apl$, 'Support: refund rate limit', 16);

SELECT pg_policy.upsert_policy('pack_support_refund_unapproved', $apl$
forbid
  principal agent "*"
  action tool "refund"
  when { context.approved == "false" }
  reason "Support: refunds require a human-approved context flag"
$apl$, 'Support: refund HITL', 14);

SELECT pg_policy.upsert_policy('pack_support_read_sql', $apl$
permit
  principal agent "*"
  action tool "execute_sql"
  when { context.statement_type in ["SELECT"] }
  reason "Support: read SQL ok"
$apl$, 'Support: allow SELECT', 40);

SELECT pg_policy.upsert_policy('pack_support_steer', $apl$
guide
  principal agent "*"
  action tool "execute_sql"
  advice "Do not SELECT * on customers; use ticket_id / order_id predicates"
  max_rows 50
$apl$, 'Support: minimum-necessary rows', 70);

SELECT 'loaded pack support' AS pack;
