# pg_agent_policy

**Agentic policy language for PostgreSQL** — guardrails, guidance, and session-aware controls beside your data.

`pg_agent_policy` is a PostgreSQL extension that lets you authorize and steer AI agents with a small, readable **Agent Policy Language (APL)**. It complements row-level security: RLS protects *rows*; `pg_agent_policy` governs *agent tools, sessions, and soft guidance*.

> **Naming:** This extension is **not** PostgreSQL's system catalog [`pg_catalog.pg_policy`](https://www.postgresql.org/docs/current/catalog-pg-policy.html), which stores RLS policies created by `CREATE POLICY`. We chose `pg_agent_policy` so agent/tool policy is not confused with that catalog.

```sql
CREATE EXTENSION pg_agent_policy;

SELECT agent_policy.upsert_policy('block_ddl', $apl$
forbid
  principal agent "research_bot"
  action tool "execute_sql"
  when { context.statement_type in ["DROP", "TRUNCATE", "ALTER", "CREATE"] }
  reason "Research agents may not run DDL"
$apl$);

SELECT agent_policy.set_setting('enforcement_mode', 'enforce');

SELECT agent_policy.check_policy(
  'research_bot',
  'execute_sql',
  '{"statement_type":"DROP"}'::jsonb
);  -- false
```

---

## Why this exists

AI agents increasingly hold database credentials and tool access. Classical privileges and RLS answer *which rows*, but not:

- May this **agent** call this **tool** with these **arguments**?
- Has this **session** already exhausted an export budget?
- Should we **steer** the agent toward a safer tool (guidance), not only deny?

Industry systems (Cedar, OPA/Rego, OpenFGA, Dogwood) solve pieces of this outside the database. `pg_agent_policy` brings an agent-native policy layer **into** PostgreSQL so policies, session events, decision logs, and data share one trust boundary.

**Start here for the argument:** [Why databases must govern agents](docs/research/07-value-thesis.md) · [Working paper (agentic-policy)](https://github.com/Agentic-Memory-Foundation/agentic-policy) · [Use cases](docs/usecases/README.md) · [Onboard in 30 minutes](docs/onboarding/README.md) · [Load a policy pack](doc/packs.md)

Thorough research lives in [`docs/research/`](docs/research/).

---

## Features

| Capability | Description |
| --- | --- |
| **APL** | Cedar/Dogwood-inspired `permit` / `forbid` / `guide` documents |
| **Guardrails** | Hard deny/allow for tools and actions |
| **Guidance** | Soft obligations (`advice`, `prefer_tool`, `max_rows`) |
| **Temporal limits** | Session event counts within intervals |
| **Graduated modes** | `log_only` → `guide` → `enforce` |
| **Decision log** | Every evaluation audited |
| **RLS complement** | Recipes that sit beside `CREATE POLICY` |
| **Non-bypassable hook (v0.2)** | C-level `ProcessUtility_hook` + `ExecutorStart_hook` make skipping `evaluate()` impossible |
| **Identity binding (v0.2)** | Trusted principal/session bound via superuser-only GUCs — agents can't spoof |
| **Append-only audit (v0.2)** | `decision_log` is INSERT-only with a tamper-evident hash chain |
| **Atomic temporal (v0.2)** | `evaluate_atomic()` serializes check-then-record so budgets can't be raced |

> **Syntax note:** PostgreSQL does not allow extensions to add core SQL keywords. APL is additional *policy* syntax invoked from SQL via dollar-quoting—the portable, PGXN-friendly approach.

---

## Install

### From source

```bash
git clone https://github.com/rahiakil/pg-policy.git
cd pg-policy
make install
psql -d mydb -c "CREATE EXTENSION pg_agent_policy;"
```

Requires PostgreSQL 15+ (the v0.2 C hooks use the PG15+ `ProcessUtility_hook` signature) and a normal PGXS toolchain (`pg_config` on `PATH`).

#### Enable the non-bypassable hook (v0.2)

The SQL-only API (`evaluate`, `check_policy`, …) works without any preload. To make enforcement **non-bypassable** — so a connection that never calls `evaluate()` still hits the referee — load the C module at startup:

```bash
# postgresql.conf
shared_preload_libraries = 'pg_agent_policy'
```

Then in SQL:

```sql
-- Bind an authenticated agent principal (superuser only — agents can't spoof this):
SET pg_agent_policy.principal_id = 'research_bot';

-- Now every statement this connection issues is checked against APL,
-- including DDL the agent never wraps in a tool call. Skipping
-- evaluate() is no longer an escape hatch.
```

Shadow mode (log denials, don't block) for a safe rollout:

```sql
SET pg_agent_policy.hook_log_only = true;
```

### Smoke test

```bash
psql -d mydb -f examples/01-basic-guardrails.sql
```

---

## Quick start

```sql
-- Soft onboarding: observe only
SELECT agent_policy.set_setting('enforcement_mode', 'log_only');

SELECT agent_policy.upsert_policy('export_budget', $apl$
forbid
  principal agent "research_bot"
  action tool "export_csv"
  when temporal {
    count(action == "export_csv") within interval '1 hour' >= 3
  }
  reason "Export budget exceeded"
$apl$);

SELECT agent_policy.open_session('sess-1', 'agent', 'research_bot');

SELECT agent_policy.evaluate(
  'agent', 'research_bot', 'tool', 'export_csv',
  '*', '*', '{}'::jsonb, 'sess-1'
);
```

Promote to enforce after a shadow period:

```sql
SELECT agent_policy.set_setting('enforcement_mode', 'enforce');
```

---

## Architecture (short)

```text
Agent / MCP gateway
        │
        ▼
 agent_policy.evaluate(...)
        │
        ├─ match APL policies (permit/forbid/guide)
        ├─ evaluate context + temporal session events
        ├─ write decision_log (+ optional events)
        └─ return { decision, obligations, reasons }
                │
                ├─ deny  → gateway blocks tool
                ├─ allow → tool runs; SQL still hits RLS
                └─ obligations → steer planner / UX
```

Design decisions: [`docs/design/`](docs/design/) · ADRs: [`docs/adr/`](docs/adr/)

---

## Documentation

| Doc | Contents |
| --- | --- |
| [APL language](doc/language.md) | Syntax reference |
| [Extension guide](doc/agent_policy.md) | Install & concepts |
| [Policy landscape](docs/research/01-policy-language-landscape.md) | Cedar, Rego, CEL, Zanzibar, Dogwood, RLS, … |
| [Extension feasibility](docs/research/02-postgres-extension-feasibility.md) | Hooks, PGXS, packaging |
| [Agentic guardrails](docs/research/03-agentic-ai-guardrails.md) | Guardrail vs guidance |
| [Industry analysis](docs/research/04-industry-analysis.md) | Living market notes |
| [Positioning](docs/research/05-competitive-positioning.md) | Category & moat |
| [Marketplace playbook](docs/research/06-marketplace-playbook.md) | PGXN → managed clouds |
| [Value thesis](docs/research/07-value-thesis.md) | Why DB + agents need plane B |
| [Capability backlog](docs/research/08-capability-backlog.md) | What to add next |
| [Use cases](docs/usecases/README.md) | Analytics, support, fintech, health, … |
| [Onboarding](docs/onboarding/README.md) | Universal path for every framework |
| [Policy packs](doc/packs.md) | Drop-in APL templates |
| [Roadmap](docs/roadmap.md) | Toward PGXN / 1.0 |

---

## Examples & packs

**Tutorials**

- [`examples/01-basic-guardrails.sql`](examples/01-basic-guardrails.sql)
- [`examples/02-agent-session-limits.sql`](examples/02-agent-session-limits.sql)
- [`examples/03-guidance-policies.sql`](examples/03-guidance-policies.sql)
- [`examples/04-rls-complement.sql`](examples/04-rls-complement.sql)
- [`examples/05-mcp-tool-pack.sql`](examples/05-mcp-tool-pack.sql)

**Domain packs** (baseline first, then one domain) — [`examples/packs/`](examples/packs/)

**Python PEP** — [`examples/integrations/evaluate_middleware.py`](examples/integrations/evaluate_middleware.py)

---

## Status

**v0.2.0** — adds the C-level hooks (`ProcessUtility_hook` + `ExecutorStart_hook`) that make `pg_agent_policy` a **non-bypassable** Plane-B firewall: a connection that never calls `evaluate()` still hits the referee. v0.2 also hardens identity binding (superuser-only GUCs), append-only audit (INSERT-only `decision_log` with a tamper-evident hash chain), and atomic temporal semantics (`evaluate_atomic()` serializes check-then-record so budgets can't be raced).

**v0.1.0** was the SQL/PL/pgSQL MVP. The SQL-only install path remains available for managed clouds that reject `shared_preload_libraries`; the hook (v0.2) is for self-hosted / CloudNativePG / RDS-custom where it is accepted.

Not yet a hardened production security boundary on its own; use with RLS, least-privilege roles, and a tool gateway. See [SECURITY.md](SECURITY.md).

Roadmap highlights: pgrx-accelerated evaluator, CEL/Cedar condition backends, AuthZEN mapping, PGXN release, managed-provider packaging.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[`pg_agent_policy` is released under the PostgreSQL License](LICENSE) — the same style of license used across the PostgreSQL ecosystem.

## Links

- Repository: https://github.com/rahiakil/pg-policy
- Issues: https://github.com/rahiakil/pg-policy/issues
- PGXN: planned (see roadmap)
