# Product Decision: pg_policy

**Date:** 2026-08-10  
**Status:** Accepted

---

## Decision

Build **`pg_policy`**, a PostgreSQL extension that provides an **Agent Policy Language (APL)** for:

1. **Guardrails** — hard allow/deny for agent/tool/data actions  
2. **Guidance** — soft obligations and advice  
3. **Session governance** — temporal quotas, prerequisites, ordering  
4. **RLS complementarity** — helpers and recipes, not a replacement  

## Language shape

Cedar/Dogwood-inspired vocabulary (`permit`, `forbid`, `guide`, `when`, temporal windows) authored inside dollar-quoted documents and managed via SQL functions:

```sql
SELECT pg_policy.upsert_policy('research_guard', $apl$
forbid
  principal agent "research_bot"
  action tool "execute_sql"
  when { context.statement_type in ["DROP", "TRUNCATE", "ALTER", "CREATE"] }
  reason "Research agents may not run DDL"
$apl$);
```

## Enforcement modes

| Mode | Behavior |
| --- | --- |
| `enforce` | Denies raise an error (or return denied for non-throwing API) |
| `log_only` | Always allow side; log would-deny |
| `guide` | Never hard-deny; return obligations/advice |

GUC: `pg_policy.enforcement_mode`

## Syntax strategy

Because Postgres extensions cannot extend `gram.y`, “additional syntax” means:

- APL documents (primary language)
- SQL function / procedure API
- Future: optional `ProcessUtility_hook` statement firewall

## Delivery plan

| Version | Deliverable |
| --- | --- |
| 0.1.0 | SQL/PL/pgSQL catalog, evaluate, events, examples, docs |
| 0.2.0 | pgrx acceleration; CEL or Cedar-backed conditions |
| 0.3.0 | RLS compile helpers; AuthZEN mapping |
| 1.0.0 | Stable APL; PGXN primary release; multi-version CI |

## License

PostgreSQL License — community-aligned for extensions.
