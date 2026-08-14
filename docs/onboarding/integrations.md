# Adapters: make pg_agent_policy work for every agent runtime

One SQL contract, many PEPs. The PEP is whatever actually invokes tools.

```text
evaluate(principal_type, principal_id, action_type, action_id,
         resource_type, resource_id, context jsonb, session_id)
  → { decision, allowed, obligations, reasons, mode, matched_policies }
```

---

## 1. Raw SQL / any driver

```sql
SELECT pg_agent_policy.evaluate(
  'agent',
  'langgraph:analytics',
  'tool',
  'execute_sql',
  'table', 'public.orders',
  jsonb_build_object(
    'statement_type', 'SELECT',
    'acting_for', 'user:42',
    'tenant_id', 'acme'
  ),
  'thread-abc'
);
```

Python: [`examples/integrations/evaluate_middleware.py`](../../examples/integrations/evaluate_middleware.py)

---

## 2. MCP Postgres servers

Wrap `query` / `execute_sql` / `explain_query`:

1. Classify `statement_type` (SELECT/INSERT/…; fail closed on unknown).
2. `evaluate` with `action_id` = MCP tool name.
3. On deny: return MCP error with `reasons` (do not execute).
4. On `max_rows`: inject LIMIT / truncate.
5. On `prefer_tool`: include in error/hint so the model can call `explain_query`.

This replaces per-server hardcoded allowlists. Keep `BEGIN READ ONLY` as defense in depth.

---

## 3. LangGraph `ToolNode`

- `session_id` = `config["configurable"]["thread_id"]`
- `principal_id` = graph/agent name
- Wrap each DB tool with the middleware before the SQL runs
- Persist checkpoints with `PostgresSaver` **and** policy in the same cluster when possible

Human-in-the-loop: map `interrupt()` to a `guide`/`forbid` that requires `context.approved == "true"` after the human resumes.

---

## 4. CrewAI / AutoGen / Letta

Assign **one principal_id per role** (`crew:researcher`, `crew:writer`). Load `examples/packs/multi-agent.sql`. The crew process is not a security boundary; pg_agent_policy is.

---

## 5. Cursor / Claude Desktop / IDE MCP

Prod connections: `devops.sql` + read-only role + `enforce`.  
Personal dev: `log_only` is acceptable; still load baseline so you see shadow_denies.

---

## 6. HTTP / AuthZEN PEP

Map:

| AuthZEN | pg_agent_policy |
| --- | --- |
| subject.type/id | principal_* |
| action.name | action_id (action_type=`tool`) |
| resource.type/id | resource_* |
| context | context jsonb |
| decision boolean | allowed |

Obligations travel in your PEP’s extra context until the HTTP sidecar exists (roadmap 0.3).

---

## 7. What if the host forbids CREATE EXTENSION?

Until Neon/RDS allowlist you:

- Run pg_agent_policy on a **policy sidecar Postgres** (evaluate remotely), or
- Load the SQL as a plain schema in a self-hosted replica used as PDP, or
- Use the same APL files in CI against a local PG.

The language and packs stay identical. The extension is the preferred PDP, not the only place APL can be stored during transition.
