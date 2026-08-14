# Capability backlog: what else pg_agent_policy should grow

**Last updated:** 2026-08-10  
Prioritized from industry gaps (MCP, Dogwood, AuthZEN, EU AI Act, multi-agent frameworks).

Legend: **P0** = next minor · **P1** = 0.2/0.3 · **P2** = 1.0+ · **Out** = non-goal

---

## Language & evaluation

| Item | Priority | Why |
| --- | --- | --- |
| `unless` clauses | P0 | Cedar parity; invert conditions without extra policies |
| `not in` / inequality on context | P0 | Real SQL-agent filters (`cost_usd < 0.05`) |
| Resource glob prefixes (`table:public.*`) | P0 | Schema allowlists |
| Temporal `formerly` / `since` / `sum` | P1 | Dogwood-class workflows (approve-then-transfer) |
| CEL or Cedar condition backend | P1 | Analyzable expressions; pgrx |
| Obligations: `require_approval`, `step_up_auth`, `redact_columns` | P1 | AuthZEN-style PEP instructions |
| Policy tests in SQL (`SELECT pg_agent_policy.assert_deny(...)`) | P0 | CI for packs |
| Compile-to-RLS helpers | P1 | Generate `CREATE POLICY` from data-plane APL |
| Partial eval / list-allowed-tools | P1 | AuthZEN search APIs; “what can this agent do?” |

## Identity & multi-agent

| Item | Priority | Why |
| --- | --- | --- |
| `acting_for` / on-behalf-of required field | P0 | HIPAA/SOX attribution; confused-deputy |
| Agent registry table | P1 | EU AI Act Art. 9 risk register |
| Delegation tuples (lite ReBAC) | P1 | Supervisor agent may spawn worker with subset |
| Break-glass role with mandatory reason | P1 | Ops reality |
| Policy version pinned on each decision | P0 | Reproducible audits |

## Audit & compliance

| Item | Priority | Why |
| --- | --- | --- |
| Append-only decision_log (revoke UPDATE/DELETE) | P0 | Art. 12 tamper resistance (best-effort in PG) |
| HMAC / hash chain optional column | P1 | Detect silent UPDATEs by superuser |
| Retention helper (`purge_decisions_older_than`) | P0 | GDPR minimization vs legal hold |
| PII hashing guidance for context | P0 | Don’t log raw customer ids |
| Export to JSONL for SIEM | P1 | Splunk/Datadog pipelines |

## Runtime / Postgres internals

| Item | Priority | Why |
| --- | --- | --- |
| `ProcessUtility_hook` DDL firewall for agent roles | P1 | Defense if someone skips `evaluate()` |
| Statement timeout / `default_transaction_read_only` recipes | P0 | Pack, not code |
| Connection GUC `pg_agent_policy.agent_id` | P1 | Implicit principal from session |
| pgrx evaluator | P1 | Latency at MCP QPS |
| Parallel-safe STABLE evaluate where possible | P1 | Use inside views carefully |

## Ecosystem “works for all”

| Item | Priority | Why |
| --- | --- | --- |
| Pack loader (`\i examples/packs/*.sql`) documented | **done (0.1)** | |
| Python PEP middleware | **done (0.1)** | |
| MCP reference wrapper | P0 | Drop-in for execute_sql |
| LangGraph ToolNode example | P0 | Production graph pattern |
| AuthZEN HTTP sidecar | P1 | Non-SQL PEPs |
| Terraform / Ansible install | P2 | Enterprise |
| pg_tle packaging experiment | P1 | RDS path |
| Editor TextMate/tree-sitter for APL | P2 | DX |

## Out of scope

- Replacing RLS or GRANT
- Running untrusted Python/JS as policy
- Core Postgres grammar patches
- Hosted SaaS requirement for the extension to be useful

---

## Suggested 0.2 cut

1. Pack test assertions  
2. `acting_for` in evaluate API (additive JSON)  
3. Append-only grants recipe  
4. Prefix globs  
5. `require_approval` obligation type  

Everything else can wait for pgrx without blocking adoption.
