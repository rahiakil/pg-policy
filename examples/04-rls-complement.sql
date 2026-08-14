-- Example 04: complement RLS (rows) with pg_agent_policy (agent tools)
CREATE EXTENSION IF NOT EXISTS pg_agent_policy;

-- Classic RLS for data plane
CREATE TABLE IF NOT EXISTS demo_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id text NOT NULL,
  amount numeric NOT NULL
);

ALTER TABLE demo_orders ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_isolation ON demo_orders;
CREATE POLICY tenant_isolation ON demo_orders
  FOR ALL
  USING (tenant_id = current_setting('app.tenant_id', true))
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- Agent control plane: even with RLS, block export tool without approval flag
SELECT pg_agent_policy.upsert_policy('export_needs_flag', $apl$
forbid
  principal agent "support_bot"
  action tool "export_csv"
  when { context.approved == "false" }
  reason "CSV export requires approval context.approved=true"
$apl$, 'Export approval gate', 10);

SELECT pg_agent_policy.set_setting('enforcement_mode', 'enforce');

SELECT pg_agent_policy.evaluate(
  'agent', 'support_bot', 'tool', 'export_csv',
  'table', 'public.demo_orders',
  '{"approved":"false"}'::jsonb
);
