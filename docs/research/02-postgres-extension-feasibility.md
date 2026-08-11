# PostgreSQL Extension Feasibility: Policy Languages & “Custom Syntax”

**Status:** living research  
**Last updated:** 2026-08-10

---

## 1. What an extension can and cannot do

### Cannot

- Add new keywords or productions to `gram.y` / `parser.c`. The SQL parser is compiled into the server binary; there is no supported extension hook for grammar plugins.
- Rely on `ProcessUtility_hook` or `raw_parser_hook` to accept unknown syntax. By the time hooks run, parse must already have succeeded.

### Can

| Capability | Hook / API | Policy use |
| --- | --- | --- |
| Intercept DDL/utility | `ProcessUtility_hook` | Block dangerous DDL; augment `CREATE POLICY` workflows; require agent tags |
| Intercept planning/execution | planner / executor hooks | Statement firewalls; rewrite; audit |
| Background workers | BGWorker API | Session-budget reapers; async policy sync |
| Custom types & operators | PGXS / pgrx | `agent_id`, policy decision types |
| Functions / procedures | SQL, C, Rust | `pg_policy.evaluate(...)` |
| GUCs | `DefineCustom*Variable` | `pg_policy.enforcement_mode` |
| Shared preload | `_PG_init` | Register hooks early |
| Catalog tables | extension scripts | Policy store, event log, obligations |

---

## 2. Patterns used by successful extensions

### 2.1 Function-first DSL (always ship this)

```sql
SELECT pg_policy.upsert($apl$ ... $apl$);
SELECT pg_policy.evaluate(
  principal := 'agent:research',
  action    := 'tool:execute_sql',
  resource  := 'table:public.orders',
  context   := '{"statement_type":"SELECT"}'::jsonb
);
```

Precedents: vast majority of PGXN extensions; `pg_durable` graph DSL via operators/functions.

### 2.2 Dollar-quoted language documents

Store Cedar-/Dogwood-/APL-shaped text; compile to JSON IR; validate against schema; evaluate in C/Rust/PL/pgSQL.

**Pros:** Real language UX; versionable in Git; independent of Postgres parser.  
**Cons:** No `psql` syntax highlighting unless editor plugins ship.

### 2.3 Reuse existing DDL shapes (`ProcessUtility_hook`)

TimescaleDB continuous aggregates pattern:

```sql
CREATE MATERIALIZED VIEW ... WITH (timescaledb.continuous) AS ...
```

For policy:

```sql
-- Conceptual (hook-augmented) — options on known statements
CREATE POLICY ...; -- still native RLS
-- Plus extension catalog via functions:
SELECT pg_policy.attach_agent_guard('orders_select', 'agent:research');
```

Cannot invent `CREATE AGENT POLICY` as a core token without a fork.

### 2.4 Procedural language embedding

PL/V8 / PL/Python policies are flexible but expand the attack surface. Prefer a **total / sandboxable** evaluator (CEL-like or Cedar-like) over general-purpose scripting for guardrails.

---

## 3. Implementation technology choices

| Stack | Pros | Cons |
| --- | --- | --- |
| Pure SQL + PL/pgSQL | Zero compile deps; easy PGXN; works everywhere | Slower; limited sandboxing; harder temporal engine |
| C + PGXS | Classic Postgres style; maximal control | Memory safety; slower iteration |
| Rust + pgrx | Memory safety; easy to embed Cedar/CEL crates | Build matrix per PG major; packaging complexity |
| Hybrid | SQL catalog + Rust evaluator | Best balance for v1→v2 |

**Recommendation:** Ship **v0.1 as SQL/PL/pgSQL** for correct semantics, tests, and docs; plan **v0.2 pgrx evaluator** for Cedar/CEL-class performance and sandboxing. This matches how serious extensions often mature and keeps early PGXN installs trivial.

---

## 4. Enforcement planes inside Postgres

```text
┌─────────────────────────────────────────────────────────────┐
│ Client / Agent runtime / MCP gateway                        │
└───────────────────────────┬─────────────────────────────────┘
                            │ SQL / protocol
┌───────────────────────────▼─────────────────────────────────┐
│ pg_policy.evaluate / check / guide                          │
│  • catalog policies                                         │
│  • session event log                                        │
│  • obligations (rate limit remaining, advice)               │
└───────────────┬─────────────────────────────┬───────────────┘
                │                             │
        soft/guide path                 hard path
                │                             │
                ▼                             ▼
        return advice JSON          RLS + GRANT + hooks
                                    (data & DDL firewall)
```

Agents that speak SQL should still face RLS. Agents that speak tools should call `pg_policy` before side effects. Gateways should do both.

---

## 5. Security considerations for in-DB policy

1. **Policy authors ≠ policy subjects.** Separate roles: `pg_policy_admin` vs agent runtime roles.
2. **No `SECURITY DEFINER` footguns** without `search_path` pinning.
3. **Default deny** for agent actions when any applicable restrictive policy exists.
4. **Audit every decision** (allow, deny, guide) with request id / session id.
5. **Log-only mode** for rollout (Dogwood/AgentCore pattern).
6. **Do not evaluate untrusted code** as policy; APL must be data, not PL/Python blobs.
7. **Superuser bypass** is a Postgres fact of life—document it like RLS docs do.

---

## 6. Packaging & distribution feasibility

| Channel | Requirement | Status for pg_policy |
| --- | --- | --- |
| GitHub | Excellent README, LICENSE, CI, docs | Design goal |
| PGXN | `META.json`, semantic version, open license | Design goal |
| apt/yum / Postgres.app | Later; often via packaging volunteers | Roadmap |
| OCI extension images | PGXN v2 / CloudNativePG direction | Watch |
| DBPaaS (Neon, Supabase, RDS, Crunchy, AlloyDB, Aurora) | Vendor allowlists | Partner after OSS traction |

PostgreSQL License or Apache-2.0 are both acceptable; **PostgreSQL License** signals community alignment for core-adjacent extensions.

---

## 7. Conclusion

A marketplace-grade policy extension is **feasible** if we:

1. Accept dollar-quoted APL + SQL APIs as “additional syntax.”
2. Optionally add hook-based enforcement for statement firewalls.
3. Co-locate policies, events, and RLS.
4. Publish to PGXN with classic PGXS layout and outstanding documentation.

True parser-level `CREATE AGENT POLICY` would require a Postgres core patch or fork—out of scope for an extension, but the *UX* can closely approximate it.
