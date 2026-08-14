# Policy packs

Packs are versioned SQL that call `pg_agent_policy.upsert_policy`. They are the supported way to onboard a domain without inventing APL from scratch.

## Load

```bash
psql "$DATABASE_URL" -f examples/packs/00-baseline.sql
psql "$DATABASE_URL" -f examples/packs/analytics.sql   # pick one domain
```

Order: **baseline first**, then one or more domain packs. Packs do not set `enforcement_mode`.

## Catalog

| File | Intent |
| --- | --- |
| `00-baseline.sql` | Universal: no DDL/admin SQL, SQL guidance, conservative export quota |
| `analytics.sql` | Text-to-SQL BI agents |
| `support.sql` | CX copilots, PII, refunds |
| `fintech.sql` | Attribution + transfer/export brakes |
| `healthcare.sql` | PHI export ban + acting_for |
| `devops.sql` | DBA/IDE agents: EXPLAIN yes, live DDL no |
| `multi-agent.sql` | Per-role tool matrix |

## Customize

1. Copy a pack.
2. Replace `"*"` principals with your `principal_id`s.
3. Adjust temporal thresholds.
4. Keep names stable (`pack_baseline_ddl`, …) so upserts update in place.

## Tests

After load, run the pack’s trailing `SELECT evaluate(...)` comments as smoke tests, or use `examples/01-*.sql` patterns.
