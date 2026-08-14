# Agent Policy Language (APL)

APL is the policy syntax shipped by **pg_agent_policy**. Documents are stored as text and compiled by `pg_agent_policy.parse_apl` / `pg_agent_policy.upsert_policy`.

> PostgreSQL extensions cannot add keywords to core SQL. APL is the extension’s language, invoked from SQL.

## Skeleton

```text
permit | forbid | guide
  principal <type> "<id>"
  action <type> "<id>"
  resource <type> "<id>"          # optional
  when { <context predicates> }   # optional
  when temporal { <temporal> }    # optional
  reason "<text>"                 # optional
  advice "<text>"                 # guide/permit
  prefer_tool "<name>"            # guide/permit
  max_rows <int>                  # guide/permit
```

## Effects

| Effect | Meaning |
| --- | --- |
| `permit` | Contributes to allow when matched |
| `forbid` | Deny overrides any permit (Cedar-like) |
| `guide` | Allow with obligations (advice, preferences) |

## Principals & actions

- Principal types: `agent`, `user`, `role`, `service`
- Action types: `tool`, `sql`, `data`, `admin`
- Resource types: `table`, `schema`, `database`, `object`
- `"*"` wildcards match any id/type where supported by matcher

## Context predicates (v0.1)

```text
when {
  context.statement_type in ["DROP", "TRUNCATE", "ALTER"]
  and context.tenant_id == "acme"
}
```

Operators: `==`, `in [...]`. Combine with `and`.

## Temporal (v0.1)

```text
when temporal {
  count(action == "export_csv") within interval '1 hour' >= 3
}
```

Requires a `session_id` on `evaluate()`.

## Examples

### Hard guardrail

```apl
forbid
  principal agent "research_bot"
  action tool "execute_sql"
  when { context.statement_type in ["DROP", "TRUNCATE", "ALTER", "CREATE"] }
  reason "Research agents may not run DDL"
```

### Soft guidance

```apl
guide
  principal agent "research_bot"
  action tool "execute_sql"
  advice "Prefer EXPLAIN ANALYZE before large scans"
  prefer_tool "sql_explain"
  max_rows 500
```

### Session quota

```apl
forbid
  principal agent "research_bot"
  action tool "export_csv"
  when temporal {
    count(action == "export_csv") within interval '1 hour' >= 3
  }
  reason "Export budget exceeded"
```

## Evaluation API

```sql
SELECT pg_agent_policy.evaluate(
  p_principal_type := 'agent',
  p_principal_id   := 'research_bot',
  p_action_type    := 'tool',
  p_action_id      := 'execute_sql',
  p_context        := '{"statement_type":"DROP"}'::jsonb,
  p_session_id     := 'sess-1'
);
```

Returns JSON:

```json
{
  "decision": "deny",
  "allowed": false,
  "matched_policies": ["block_ddl"],
  "obligations": [],
  "reasons": ["Research agents may not run DDL"],
  "mode": "enforce"
}
```
