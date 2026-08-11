# Universal onboarding (works for every stack)

**Time:** ~30 minutes to shadow mode · 1–7 days to enforce  
**Requires:** PostgreSQL 14+, ability to `CREATE EXTENSION` (or load the SQL in a lab)

This path is the same whether the client is **psql**, **MCP**, **LangGraph**, **CrewAI**, **Cursor**, or a homegrown tool gateway.

```text
Install → Identity → Baseline pack → Shadow → Domain pack → Honor obligations → Enforce
```

---

## Day 0 — Install the kernel

```sql
CREATE EXTENSION pg_policy;
SELECT pg_policy.set_setting('enforcement_mode', 'log_only');  -- never start at enforce
```

From a checkout:

```bash
psql "$DATABASE_URL" -f examples/packs/00-baseline.sql
```

You now have DDL/admin forbids + SQL guidance for every agent id `"*"`.

---

## Day 0 — Identity convention (do not skip)

Pick **stable strings**. Changing them later orphans logs.

| Field | Convention | Example |
| --- | --- | --- |
| `principal_type` | `agent` | `agent` |
| `principal_id` | `{framework}:{name}` | `langgraph:analytics`, `cursor:compose`, `mcp:postgres` |
| `context.acting_for` | human user id (opaque) | `user:42` or HMAC of email |
| `context.tenant_id` | tenant key also used by RLS | `acme` |
| `session_id` | one per user-visible chat/run | LangGraph `thread_id`, MCP session, `gen_random_uuid()` |

Open a session when the agent run starts:

```sql
SELECT pg_policy.open_session(
  'thread-abc',
  'agent',
  'langgraph:analytics',
  '{"acting_for":"user:42","tenant_id":"acme"}'::jsonb
);
```

---

## Day 0 — Wire the one hook

**Every tool call** (not every SQL string inside a transaction) must hit `evaluate` **before** side effects.

Pseudo-contract (any language):

```text
decision = evaluate(agent, tool, context, session_id)
if not decision.allowed:  return error(decision.reasons)
apply(decision.obligations)   # LIMIT, prefer other tool, show advice
execute_tool()
```

Copy-paste adapters: [`integrations.md`](integrations.md) and [`examples/integrations/`](../../examples/integrations/).

If you cannot wrap tools yet, you are **not ready for enforce**. Stay in `log_only` and sample `pg_policy.decision_log`.

---

## Day 1 — Prove shadow mode

```sql
SELECT at, principal_id, action_id, decision, reasons, obligations
FROM pg_policy.decision_log
ORDER BY at DESC
LIMIT 50;
```

Look for:

- `shadow_deny` obligations → policies that *would* have blocked
- agents with empty `acting_for`
- tools you forgot to name (`action_id` junk)

Fix names and context **before** loading a stricter pack.

---

## Day 2 — Load a domain pack

| If you are… | Load |
| --- | --- |
| BI / text-to-SQL | `examples/packs/analytics.sql` |
| Support / CX | `examples/packs/support.sql` |
| Payments / ledger | `examples/packs/fintech.sql` |
| PHI / clinical | `examples/packs/healthcare.sql` |
| DBA / migrations | `examples/packs/devops.sql` |
| Multi-agent crew | `examples/packs/multi-agent.sql` |

Packs are idempotent `upsert_policy` scripts. They do not change `enforcement_mode`.

Also enable RLS on tenant tables (`examples/04-rls-complement.sql` pattern). **Packs do not replace RLS.**

---

## Day 3–7 — Honor obligations in the PEP

`guide` never blocks. Your gateway must implement:

| Obligation `type` | PEP behavior |
| --- | --- |
| `max_rows` | Inject `LIMIT` / truncate result |
| `prefer_tool` | Hint the model or auto-route |
| `advice` | Put in tool error/warning channel |
| `shadow_deny` / `would_deny` | Metric + optional user-visible warning |

Until `max_rows` is enforced in the MCP, the policy is theater.

---

## Promote to enforce

```sql
-- only after: no surprise shadow_denies you disagree with
SELECT pg_policy.set_setting('enforcement_mode', 'enforce');
```

Rollback is one row:

```sql
SELECT pg_policy.set_setting('enforcement_mode', 'log_only');
```

---

## Least-privilege Postgres role (required for “works for all”)

Never connect the agent as table owner or superuser.

```sql
CREATE ROLE agent_runtime NOINHERIT LOGIN PASSWORD '...';
GRANT USAGE ON SCHEMA public TO agent_runtime;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO agent_runtime;  -- tighten per pack
GRANT USAGE ON SCHEMA pg_policy TO agent_runtime;
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA pg_policy TO agent_runtime;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_policy TO agent_runtime;
-- Do NOT grant BYPASSRLS
ALTER ROLE agent_runtime SET default_transaction_read_only = on;  -- analytics/support
```

Writes: dedicated `agent_writer` with `default_transaction_read_only = off` and a *narrower* pack.

---

## Definition of done

- [ ] Extension installed; mode started `log_only`
- [ ] Stable `principal_id` / `session_id` / `acting_for`
- [ ] All tools go through `evaluate`
- [ ] Baseline + one domain pack loaded
- [ ] RLS enabled on tenant tables
- [ ] Obligations implemented in the gateway
- [ ] Week of shadow review
- [ ] `enforce` with a documented rollback

That onboarding is identical for every framework. Only the adapter file changes.
