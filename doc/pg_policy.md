# pg_policy

`pg_policy` adds an **Agent Policy Language (APL)** to PostgreSQL for AI-agent guardrails, guidance, and session-aware controls. It complements—not replaces—row-level security.

## Install

```bash
make install
psql -c "CREATE EXTENSION pg_policy;"
```

## Quick start

```sql
SELECT pg_policy.upsert_policy('block_ddl', $apl$
forbid
  principal agent "research_bot"
  action tool "execute_sql"
  when { context.statement_type in ["DROP", "TRUNCATE", "ALTER", "CREATE"] }
  reason "Research agents may not run DDL"
$apl$);

SELECT pg_policy.set_setting('enforcement_mode', 'enforce');

SELECT pg_policy.evaluate(
  'agent', 'research_bot', 'tool', 'execute_sql',
  '*', '*', '{"statement_type":"DROP"}'::jsonb
);
```

## Concepts

| Concept | Role |
| --- | --- |
| Guardrail (`forbid`/`permit`) | Hard authorization |
| Guidance (`guide`) | Soft obligations and advice |
| Session events | Temporal quotas and prerequisites |
| Decision log | Audit trail for every evaluation |
| Enforcement mode | `log_only` → `guide` → `enforce` |

## See also

- [APL language reference](language.md)
- [Architecture & research](../docs/design/00-product-decision.md)
- [Examples](../examples/)
