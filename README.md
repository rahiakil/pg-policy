# pg_agent_policy

**Agentic policy language for PostgreSQL** — guardrails, guidance, and session-aware controls beside your data.

`pg_agent_policy` is a PostgreSQL extension that lets you authorize and steer AI agents with a small, readable **Agent Policy Language (APL)**. It complements row-level security: RLS protects *rows*; `pg_agent_policy` governs *agent tools, sessions, and soft guidance*.

> **Naming:** This extension is **not** PostgreSQL's system catalog [`pg_catalog.pg_policy`](https://www.postgresql.org/docs/current/catalog-pg-policy.html), which stores RLS policies created by `CREATE POLICY`. We chose `pg_agent_policy` so agent/tool policy is not confused with that catalog.

```sql
CREATE EXTENSION pg_agent_policy;

SELECT pg_agent_policy.upsert_policy('block_ddl', $apl$
forbid
  principal agent "research_bot"
  action tool "execute_sql"
  when { context.statement_type in ["DROP", "TRUNCATE", "ALTER", "CREATE"] }
  reason "Research agents may not run DDL"
$apl$);

SELECT pg_agent_policy.set_setting('enforcement_mode', 'enforce');

SELECT pg_agent_policy.check(
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

**Start here for the argument:** [Why databases must govern agents](docs/research/07-value-thesis.md) · [Industry-track working paper](paper/db-policy-for-agents.md) · [Use cases](docs/usecases/README.md) · [Onboard in 30 minutes](docs/onboarding/README.md) · [Load a policy pack](doc/packs.md)

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
| **SQL-only v0.1** | No compilers required to try it |

> **Syntax note:** PostgreSQL does not allow extensions to add core SQL keywords. APL is additional *policy* syntax invoked from SQL via dollar-quoting—the portable, PGXN-friendly approach.

---

## Install

### From source

```bash
git clone https://github.com/rahiakil/pg-agent-policy.git
cd pg-agent-policy
make install
psql -d mydb -c "CREATE EXTENSION pg_agent_policy;"
```

Requires PostgreSQL 14+ (tested target: 14–17) and a normal PGXS toolchain (`pg_config` on `PATH`).

### Smoke test

```bash
psql -d mydb -f examples/01-basic-guardrails.sql
```

---

## Quick start

```sql
-- Soft onboarding: observe only
SELECT pg_agent_policy.set_setting('enforcement_mode', 'log_only');

SELECT pg_agent_policy.upsert_policy('export_budget', $apl$
forbid
  principal agent "research_bot"
  action tool "export_csv"
  when temporal {
    count(action == "export_csv") within interval '1 hour' >= 3
  }
  reason "Export budget exceeded"
$apl$);

SELECT pg_agent_policy.open_session('sess-1', 'agent', 'research_bot');

SELECT pg_agent_policy.evaluate(
  'agent', 'research_bot', 'tool', 'export_csv',
  '*', '*', '{}'::jsonb, 'sess-1'
);
```

Promote to enforce after a shadow period:

```sql
SELECT pg_agent_policy.set_setting('enforcement_mode', 'enforce');
```

---

## Architecture (short)

```text
Agent / MCP gateway
        │
        ▼
 pg_agent_policy.evaluate(...)
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
| [Extension guide](doc/pg_agent_policy.md) | Install & concepts |
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

**v0.1.0** — research-backed SQL/PL/pgSQL MVP suitable for experimentation and API feedback. Not yet a hardened production security boundary; use with RLS, least-privilege roles, and a tool gateway. See [SECURITY.md](SECURITY.md).

Roadmap highlights: pgrx-accelerated evaluator, CEL/Cedar condition backends, AuthZEN mapping, PGXN release, managed-provider packaging.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[`pg_agent_policy` is released under the PostgreSQL License](LICENSE) — the same style of license used across the PostgreSQL ecosystem.

## Links

- Repository: https://github.com/rahiakil/pg-agent-policy
- Issues: https://github.com/rahiakil/pg-agent-policy/issues
- PGXN: planned (see roadmap)
