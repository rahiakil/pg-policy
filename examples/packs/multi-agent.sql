-- Pack: multi-agent crew
-- Replace principal ids with your runtime names (crew:researcher, …).

CREATE EXTENSION IF NOT EXISTS pg_agent_policy;

SELECT pg_agent_policy.upsert_policy('pack_ma_researcher_sql', $apl$
permit
  principal agent "crew:researcher"
  action tool "execute_sql"
  when { context.statement_type in ["SELECT"] }
  reason "Researcher may read"
$apl$, 'Multi-agent: researcher SELECT', 40);

SELECT pg_agent_policy.upsert_policy('pack_ma_researcher_no_mail', $apl$
forbid
  principal agent "crew:researcher"
  action tool "send_email"
  reason "Researcher may not send email"
$apl$, 'Multi-agent: researcher no email', 10);

SELECT pg_agent_policy.upsert_policy('pack_ma_writer_no_sql', $apl$
forbid
  principal agent "crew:writer"
  action tool "execute_sql"
  reason "Writer consumes research notes, not the warehouse"
$apl$, 'Multi-agent: writer no SQL', 10);

SELECT pg_agent_policy.upsert_policy('pack_ma_writer_mail', $apl$
permit
  principal agent "crew:writer"
  action tool "send_email"
  when { context.approved == "true" }
  reason "Writer may email after approval"
$apl$, 'Multi-agent: writer email with approval', 40);

SELECT pg_agent_policy.upsert_policy('pack_ma_writer_mail_block', $apl$
forbid
  principal agent "crew:writer"
  action tool "send_email"
  when { context.approved == "false" }
  reason "Writer email requires approval"
$apl$, 'Multi-agent: writer email HITL', 9);

SELECT pg_agent_policy.upsert_policy('pack_ma_critic_read', $apl$
permit
  principal agent "crew:critic"
  action tool "execute_sql"
  when { context.statement_type in ["SELECT"] }
  reason "Critic may spot-check data"
$apl$, 'Multi-agent: critic SELECT', 40);

SELECT pg_agent_policy.upsert_policy('pack_ma_supervisor_quota', $apl$
forbid
  principal agent "crew:supervisor"
  action tool "spawn_agent"
  when temporal {
    count(action == "spawn_agent") within interval '10 minutes' >= 5
  }
  reason "Supervisor spawn fan-out limit"
$apl$, 'Multi-agent: spawn budget', 10);

SELECT 'loaded pack multi-agent' AS pack;
