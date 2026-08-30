# Policy Beside the Data: An In-Database Control Plane for Agentic Workloads

**Working paper — industry track (CIDR 2027 / VLDB–SIGMOD 2027)**  
Agentic Memory Foundation · artifact: [`pg_agent_policy`](https://github.com/rahiakil/pg-policy)  
August 2026

---

## Abstract

AI agents have become a new class of database client: they invent SQL at runtime, chain tools through the Model Context Protocol (MCP), and often share a service account. Classical privileges and row-level security (RLS) answer *which rows*, but not *which tool, in which session, after which prior acts, with what soft guidance*. Industry has responded with sidecars (OPA/Cedar), relationship databases (Zanzibar/SpiceDB), per-process MCP regex firewalls, and—since March 2026—**Oracle Deep Data Security** in Oracle AI Database 26ai, which enforces identity-aware row/column grants at SQL rewrite time. We argue that for agent–data interaction the **database is the source of truth**, but that two planes must stay distinct: **Plane A** (which rows/columns) and **Plane B** (which tool, with what session history and obligations). Oracle’s new system validates Plane A for the Oracle SQL path; it does not address tool orchestration, temporal quotas, soft guidance, or non-SQL MCP tools.

We survey equivalent mechanisms (Postgres/SQL Server RLS, Oracle VPD/RAS/Deep Data Security, IBM LBAC, Cedar, Dogwood, Rego, Polar, OpenFGA, pgauthz, statement firewalls) and show that **no open PostgreSQL extension** combines tool-native vocabulary, session-temporal constraints, soft guidance, and `CREATE EXTENSION` packaging. We present **pg_agent_policy** and **APL**, a small total language evaluated inside PostgreSQL for Plane B, with layered guardrails (GRANT → RLS → `evaluate()` → model filters). We separate two costs that the “it will slow queries” objection conflates: (1) **per-row RLS** on unindexed columns (3–8× in published pgbench, ≈2% p95 once indexed) versus (2) **once-per-tool** PDP evaluation (APL matcher 16–263 µs p50 for 3–200 policies in a Python oracle; reproducible PL/pgSQL wall-time via `experiments/bench_evaluate_pg.sh`, conservative envelope 0.8–1.5 ms, **&lt;0.2% of a typical 800 ms LLM tool loop**). A sensitivity cost model shows expected-loss ratios that dominate millisecond taxes under any plausible cross-tenant incident cost. The industrial recommendation is architectural: **index RLS (or Oracle DATA GRANT) for rows; evaluate APL for tools; never put tool policy in the hot row path.**

---

## 1. Introduction

PostgreSQL spent three decades optimizing for a human-shaped client: a role, a session, a handful of statements, intent that is mostly honest. Agentic systems invert that contract. A single user prompt can become schema discovery, multi-join SQL, CSV export, and a sibling agent’s email tool—none of which were reviewed by a developer. Retrieval-augmented generation (RAG) already taught the industry that *relevance is not authorization*. Tool-using agents expand the surface: autonomous schema discovery, SQL construction, writes, exports, and confused-deputy delegation [securing-the-agent-2026, aws-agent-mesh].

Two camps now argue past each other:

1. **Keep policy out of the database.** Authorization is an application concern; in-DB predicates (especially RLS) surprise the planner and “slow everything down.” Sidecars (OPA), Cedar services, and MCP process filters are the right PEP.
2. **The database is the last referee.** If the agent holds a connection string, any check that is not in the server can be walked around—exactly as forgotten `WHERE tenant_id = …` clauses have walked around application filters for twenty years.

Oracle’s March 2026 launch of **Deep Data Security** in Oracle AI Database 26ai lands firmly in camp (2) for the SQL path: `CREATE DATA GRANT` policies rewrite queries so agents cannot omit end-user predicates, with identity propagated via `ORA_END_USER_CONTEXT` [oracle-dds-blog, oracle-dds-docs]. That validates the thesis that agentic workloads need database-resident authorization—but Oracle’s design is **Plane A** (row/column/cell isolation), not tool/session orchestration across MCP.

Both camps are half right. The first is correct that **per-row policy on unindexed columns is expensive**. The second is correct that **agents will talk to the database**. The mistake is treating “policy in the database” as a single mechanism. We split the control plane:

| Plane | Question | Mechanism |
| --- | --- | --- |
| A — data isolation | Which rows/columns exist for this identity? | `GRANT` + RLS / VPD |
| B — agent/tool control | May this agent call this tool, given session history? | **APL / pg_agent_policy `evaluate()`** |
| C — model/content | Is the prompt/output allowed? | Bedrock Guardrails, Llama Guard, … |

Plane B is what production MCP Postgres servers are reinventing in Node (read-only transactions, row caps, DDL regexes, denial logs) [safe-postgres-mcp, pgguard-mcp, postgres-mcp-pro]. Those are *policies*. They should be data, versioned next to RLS, evaluated in SQL, not unique snowflakes per gateway binary.

**Contributions.** (1) An updated survey—including Oracle Deep Data Security (26ai)—that maps vendor and open-source systems to Planes A/B/C. (2) APL and pg_agent_policy as an open PostgreSQL artifact for **Plane B**: language, SQL API, packs, layered guardrails. (3) A cost/latency analysis that *disentangles* RLS row-path overhead from once-per-tool PDP cost, with Python-oracle and PL/pgSQL microbench scripts plus an expected-loss model. (4) An onboarding contract that works for MCP, LangGraph, CrewAI, and IDE agents.

This is an **industry-track / CIDR-style systems paper**: an open extension, experience-shaped architecture, and measurements of a v0.1 SQL engine—not a claim that APL replaces Cedar’s SMT analyzer.

---

## 2. What agents need that row security does not provide

Classical IAM: *May principal P perform action A on resource R right now?*

Agents additionally require:

- **Tool identity** — `execute_sql` vs `explain_query` vs `export_csv` vs `refund`.
- **Argument constraints** — statement type, tenant in context, `acting_for` (human attribution for HIPAA/SOX).
- **Session memory** — export budgets, refund velocity, “approval happened in this thread.”
- **Soft guidance** — obligations (`max_rows`, `prefer_tool`, `advice`), not only deny.
- **Graduated enforcement** — `log_only` → `guide` → `enforce` (Sentinel-like; Dogwood `LOG_ONLY`).
- **Audit that is not the LLM’s service account** — EU AI Act Art. 12-style trails: who, which agent, which tool, which policy version, correlated by session [eu-ai-act].

RLS is necessary and insufficient. It cannot express “this MCP tool may not run DDL,” “CSV export at most five times per hour,” or “prefer `explain_query`.” Putting those predicates into `CREATE POLICY … USING` would be the design error the performance camp rightly fears: they would run **per row**.

---

## 3. Survey: equivalent and adjacent technologies

We asked: *is there already an in-database agent policy language?* Short answer: **Oracle now covers Plane A for agentic SQL on 26ai; no open Postgres extension covers Plane B.** Long answer: rich partials.

### 3.1 In-database row/column security (Plane A)

| System | Model | Agent-native? | Temporal / guidance? |
| --- | --- | --- | --- |
| PostgreSQL RLS | SQL boolean `USING` / `WITH CHECK` | No | No |
| Oracle VPD (`DBMS_RLS`) | Dynamic `WHERE`; column-relevant policies | No | No |
| Oracle RAS | Intended VPD successor | No | No |
| **Oracle Deep Data Security (26ai)** | `CREATE DATA GRANT` + `ORA_END_USER_CONTEXT`; engine rewrite | **Yes** (identity-aware agent workloads) | No |
| SQL Server RLS | Predicate functions | No | No |
| IBM DB2 LBAC | Labels on rows/columns | No | No |

These are the correct *row* plane. Oracle VPD’s lesson for agents is architectural: the engine rewrites statements so the client cannot forget the predicate [oracle-vpd]. **Oracle Deep Data Security** modernizes that pattern for agentic AI: end users (`CREATE END USER`), data roles, and declarative `CREATE DATA GRANT … AS SELECT (cols) ON view WHERE predicate` policies evaluated before results return [oracle-dds-docs, oracle-data-grant]. Workload-specific rules let agents and legacy apps share a schema with different grants. Controlled privilege elevation limits shared high-privilege service accounts. Select AI + MCP case studies show agents generating SQL while the database filters by authenticated end-user identity—solving the “shared DB account” problem for **SQL results**, not for **tool choice**.

Postgres RLS is the same rewrite idea with SQL-native policy objects [pg-rls]. None of these Plane A systems speak *tools* (`execute_sql` vs `export_csv`), *session temporal quotas*, or *soft guidance obligations*.

### 3.2 Policy-as-code engines (usually sidecars)

| System | Language | Strength | Gap for PG agents |
| --- | --- | --- | --- |
| OPA | Rego | Infra-wide, structured output | Sidecar; Rego learning curve; not co-located with SQL |
| Cedar | permit/forbid + schema | Fast, analyzable (SMT) | Stateless; AWS-adjacent runtime |
| **Dogwood** | Cedar + `when temporal` | Agent sequences, guardrail providers | Runtime, not `CREATE EXTENSION` |
| HashiCorp Sentinel | Graded enforcement | Advisory / soft / hard | HashiCorp products |
| Oso Polar | Logic rules | Can emit SQL fragments | Engine typically outside PG |

Cedar and Dogwood are the closest *linguistic* relatives of APL [cedar2024, dogwood2026]. Dogwood validates the product category (prerequisites, rate limits, ordering). It does not live beside RLS.

### 3.3 Relationship engines

Zanzibar / SpiceDB / OpenFGA / Keto store tuples and answer reachability [zanzibar2019, spicedb, openfga]. Excellent for “user is viewer of document.” Agents need that *and* ABAC on tool arguments. These systems often **use Postgres as a datastore** while remaining a second operational plane—the split we are trying to avoid for *data* tools.

### 3.4 Postgres-adjacent extensions (closest cousins)

| Extension | What it does | Not |
| --- | --- | --- |
| **pgauthz** + optional **pg_cel** | In-PG ABAC; CEL conditions; OPA overlay | Agent/tool/guidance/temporal product |
| **pg_command_fw** | `ProcessUtility` DDL firewall via GUCs | No language, no sessions |
| sepgsql | SELinux | Not app-authorable |

pgauthz is the strongest prior *in-PG authorization framework*. pg_agent_policy is narrower and more opinionated: agent principals, MCP tool names, `guide` obligations, session event counts, policy packs, PGXN packaging.

### 3.5 MCP Postgres servers (Plane B reinvented in-process)

After the deprecated `@modelcontextprotocol/server-postgres` `COMMIT; DROP` class of bypasses, serious servers independently implemented: `BEGIN READ ONLY`, `statement_timeout`, row caps, AST/single-statement checks, audit of denials. That duplication is the industrial smell that a database-resident PDP should exist.

**Finding.** Plane A is now crowded—including Oracle’s agent-marketed Deep Data Security—and sidecar Plane B is crowded (Cedar, Dogwood, MCP regex). The remaining gap for the **Postgres open ecosystem** is: **tool/session policy as a PostgreSQL extension**, with guidance and temporal constraints, complementing RLS the way Oracle DATA GRANT complements VPD on 26ai.

---

## 4. Layered guardrails (the architecture)

```text
 LLM / agent runtime (LangGraph, CrewAI, Cursor, …)
        │  Plane C: content filters (optional)
        ▼
 Tool gateway / MCP  ── pg_agent_policy.evaluate()   Plane B (once per tool)
        │                 deny → error + reasons
        │                 allow + obligations → inject LIMIT, prefer tool
        ▼
 PostgreSQL
   GRANT / role          Plane A.0
   RLS / FORCE RLS       Plane A.1  (per row, indexed)
   statement timeout,
   default_transaction_read_only
   decision_log          Plane B audit (same transaction/cluster)
```

**Invariant:** Plane B must not be implemented as RLS `USING` clauses. `evaluate()` runs **once per tool invocation**, then the SQL tool still hits RLS.

**Fail-closed sentinels** (PEP contract): missing `acting_for` / `tenant_id` → `"unset"`; missing `approved` → `"false"`. Packs match those sentinels so a sloppy gateway cannot silently permit.

**Defense in depth if someone skips `evaluate()`:** read-only role, `default_transaction_read_only`, no `BYPASSRLS`, optional future `ProcessUtility_hook` (pg_command_fw-style) for DDL. pg_agent_policy v0.1 does not yet install that hook; the paper treats it as Plane B′.

---

## 5. APL and pg_agent_policy (the artifact)

PostgreSQL extensions cannot extend `gram.y`. “Additional syntax” is a **dollar-quoted document** compiled by `parse_apl` and stored in catalog tables—the same honest constraint Timescale/pg_trickle document for custom DDL.

### 5.1 Language (v0.1)

```apl
forbid
  principal agent "langgraph:analytics"
  action tool "execute_sql"
  when { context.statement_type in ["DROP", "TRUNCATE", "ALTER", "CREATE"] }
  reason "Analytics agents may not run DDL"

guide
  principal agent "langgraph:analytics"
  action tool "execute_sql"
  advice "Prefer explain_query before large scans"
  prefer_tool "explain_query"
  max_rows 200

forbid
  principal agent "langgraph:analytics"
  action tool "export_csv"
  when temporal {
    count(action == "export_csv") within interval '1 hour' >= 5
  }
  reason "Export budget exceeded"
```

Effects: `permit` / `forbid` / `guide`. Deny overrides (Cedar-like). Modes: `log_only`, `guide`, `enforce`.

### 5.2 SQL API

```sql
CREATE EXTENSION pg_agent_policy;
SELECT pg_agent_policy.set_setting('enforcement_mode', 'log_only');  -- never start at enforce

SELECT pg_agent_policy.upsert_policy('block_ddl', $apl$
forbid
  principal agent "langgraph:analytics"
  action tool "execute_sql"
  when { context.statement_type in ["DROP", "TRUNCATE", "ALTER", "CREATE"] }
  reason "No DDL"
$apl$);

SELECT pg_agent_policy.open_session('thread-abc', 'agent', 'langgraph:analytics',
  '{"acting_for":"user:42","tenant_id":"acme"}'::jsonb);

SELECT pg_agent_policy.evaluate(
  'agent', 'langgraph:analytics', 'tool', 'execute_sql',
  'table', 'public.orders',
  '{"statement_type":"DROP","acting_for":"user:42","tenant_id":"acme"}'::jsonb,
  'thread-abc'
);
-- { "decision":"allow", "obligations":[{"type":"shadow_deny",...}], "mode":"log_only" }

SELECT pg_agent_policy.set_setting('enforcement_mode', 'enforce');
```

Plane A remains ordinary RLS:

```sql
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_iso ON orders
  USING (tenant_id = current_setting('app.tenant_id', true))
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true));
-- Index the policy column or you will measure the wrong slowdown:
CREATE INDEX ON orders (tenant_id);
```

### 5.3 Packs (templates that work)

Load baseline, then one domain (`examples/packs/`): analytics, support, fintech, healthcare, devops, multi-agent. None flip `enforcement_mode`. Fintech/healthcare packs require `acting_for` so service-account-only logging fails closed.

---

## 6. The slowdown objection — analysis and experiments

### 6.1 Two different costs

| Mechanism | When it runs | Failure mode if naive | Healthy cost |
| --- | --- | --- | --- |
| RLS `USING (tenant_id = …)` | **Every row** considered by the plan | Unindexed seq scan: **3–8×** latency in community pgbench [rls-supabase-pgbench] | Indexed: **~2% p95** vs equivalent manual `WHERE` in a 1M-row study [rls-devto-2026] |
| `auth.uid()` per row | Every row | Function called 10^6 times | `(SELECT auth.uid())` InitPlan; `STABLE` |
| APL `evaluate()` | **Once per tool** | Scanning 10k policies linearly in PL/pgSQL | Tens–hundreds of µs match + sub-ms SQL/audit |
| OPA/Cedar sidecar | Once per tool **plus RTT** | Cross-AZ 5–15 ms | Same-host µs–ms |
| LLM tool loop | Once per step | — | **~0.5–2 s** |

The slogan “policy in the database slows queries” almost always refers to **the first two rows**, not the third.

### 6.2 Experiment A — APL matcher microbench (Python oracle)

We implemented a Python oracle of pg_agent_policy v0.1 matching (`experiments/policy_engine.py`, `bench_evaluate.py`): glob on principal/action/resource, JSON condition `eq`/`in`, temporal count, deny-overrides. Workload: baseline pack (DDL forbid matches `statement_type=DROP`) padded with non-matching policies.

**Machine:** local CPython 3.9, 8000 iterations after 400 warmup (Aug 2026).

| Policies | p50 (µs) | p95 (µs) | p99 (µs) |
| ---: | ---: | ---: | ---: |
| 3 | 16.0 | 59.6 | 136.7 |
| 10 | 26.9 | 92.0 | 199.8 |
| 25 | 43.4 | 120.8 | 187.8 |
| 50 | 83.3 | 246.9 | 565.6 |
| 100 | 134.5 | 250.4 | 388.6 |
| 200 | 263.4 | 472.0 | 796.3 |

Linear in the number of policies, as expected for v0.1 full scans. Production packs are tens of policies, not thousands. **Even 200 policies stay sub-millisecond in-process.**

**What this is not.** It is not `SPI` / PL/pgSQL / WAL of `decision_log`. We therefore quote a **conservative envelope** for v0.1 in PostgreSQL on the *same connection* as the upcoming SQL: **0.8 ms** evaluate+log, **1.5 ms** with extra audit chatter.

### 6.2b Experiment A′ — PL/pgSQL wall time (reproducible)

`experiments/bench_evaluate_pg.sh` loads the extension DDL into PostgreSQL 14–17 (Docker or local), pads policies, and measures `clock_timestamp()` around `evaluate()` including `decision_log` insert. Results are written to `experiments/results/evaluate_pg_microbench.json`. CI should run this script when a Postgres service is available; until then we report the **envelope above**, not Python-oracle µs as PostgreSQL latency. A pgrx/Cedar backend (roadmap) targets Cedar’s µs class [cedar2024]. Zanzibar’s published p95 &lt; 10 ms includes a global distributed graph [zanzibar2019]—a different problem.

### 6.3 Experiment B — latency vs the agent loop

Assume an 800 ms model+tool step (typical; often worse):

| Extra PDP | Added ms | % of LLM loop |
| --- | ---: | ---: |
| App `if` (no enforcement) | 0.05 | 0.006% |
| pg_agent_policy same-conn (envelope) | 0.8 | **0.10%** |
| MCP regex + extra hop | 1.5 | 0.19% |
| OPA + cross-AZ | 9.0 | 1.13% |

User-perceived latency is dominated by the model. **Optimizing away 0.8 ms of `evaluate()` to save a cross-tenant leak is a category error.**

### 6.4 Experiment C — expected loss vs latency tax

`experiments/cost_model.py` (sensitivity, **not** actuarial): 10 000 tool calls/day, 4 attempted-incident opportunities/year, $250k fully loaded cost if a bypass is realized (IR + notification; many orgs would quote more). Bypass probabilities are *ordinal*: app filters leak more than regex MCP, which leak more than a sidecar, which leak more than evaluate+RLS (residual = superuser/`BYPASSRLS` misconfig).

| Architecture | Assumed P(bypass) | E[loss]/yr | Latency tax/yr* | Extra ms / LLM loop |
| --- | ---: | ---: | ---: | ---: |
| App filter only | 8% | **$80 000** | $0.01 | 0.006% |
| MCP regex gateway | 2% | $20 000 | $0.18 | 0.19% |
| OPA sidecar (cross-AZ) | 0.5% | $5 000 | $1.10 | 1.13% |
| pg_agent_policy evaluate | 0.05% | $500 | $0.10 | 0.10% |
| pg_agent_policy + RLS | 0.01% | $100 | $0.12 | 0.13% |

\*CPU-hour tax of extra milliseconds at $0.12/h—intentionally showing that **compute tax is noise**.

If P(bypass) for “app only” is 1% instead of 8%, E[loss] is still $10k/yr vs sub-dollar latency tax. The inequality is robust. The industrial takeaway is not the exact dollars; it is that **breach expected value and planner-path RLS mistakes dwarf PDP microseconds**.

### 6.5 When in-DB policy *does* hurt (and what to do)

1. **Unindexed RLS** on large facts tables — index `tenant_id`; wrap GUCs in `(SELECT current_setting(...))`.
2. **Many OR-combined permissive policies** — planner pain [bytebase-rls]; prefer fewer, simpler RLS expressions.
3. **Non-LEAKPROOF functions** blocking qual pushdown — keep RLS predicates simple equality.
4. **Calling `evaluate()` inside a per-row SQL function** — **don’t**. That is putting Plane B on the Plane A path.
5. **Synchronous remote HTTP from a `SECURITY DEFINER` trigger** — don’t; that is the latency people imagine.

pg_agent_policy’s API is deliberately a **tool-level function**, not a row trigger.

---

## 7. Value that is not latency

Co-location buys properties sidecars simulate poorly:

1. **One trust boundary** — the agent’s SQL and the decision share a cluster (and can share a transaction for “check then execute” if the PEP so wraps).
2. **No second source of tenant truth** — `context.tenant_id` can be the same GUC RLS reads.
3. **Session events next to data** — temporal quotas do not require a separate Redis.
4. **Audit queryability** — `SELECT * FROM pg_agent_policy.decision_log WHERE reasons && ARRAY['No DDL']`.
5. **Pack portability** — the same APL loads in CI Postgres, on-prem, and (once allowlisted) Neon/RDS.
6. **Gateway independence** — swapping MCP servers does not rewrite policy.

These are why we call the database the source of truth: not because it must evaluate every boolean faster than Cedar, but because **the rows, the tenants, and the agent’s side effects already live there**.

---

## 8. Threats to validity

- Python oracle matcher ≠ PL/pgSQL wall time; use `bench_evaluate_pg.sh` for reproducible PG numbers and the 0.8–1.5 ms envelope until CI installcheck is wired.
- **Oracle Deep Data Security** enforces Plane A at SQL rewrite time without a PEP call; pg_agent_policy v0.1 requires the PEP to invoke `evaluate()`—defense-in-depth (`ProcessUtility_hook`, read-only roles) is roadmap, not shipped.
- P(bypass) in the cost model is assumed ordinal sensitivity, not red-team measurement.
- v0.1 APL is a small total language (no `formerly`/`since`, no SMT). Cedar/Dogwood remain stronger analyzers.
- Superusers still bypass RLS; we document this rather than pretend otherwise.
- Managed Postgres allowlists (Neon, RDS) currently block arbitrary extensions; PGXN is the open path, vendor programs are political. Oracle DDS is 26ai-only and proprietary.

---

## 9. Related work (short)

**Database row/column security:** PostgreSQL RLS [pg-rls]; Oracle VPD/RAS and **Deep Data Security** (26ai DATA GRANT, identity-aware agent workloads) [oracle-vpd, oracle-dds-blog, oracle-dds-docs]; SQL Server RLS; IBM LBAC.

**Policy-as-code and agents:** Cedar [cedar2024]; Dogwood temporal agent guardrails [dogwood2026]; OPA/Rego [opa]; Oso Polar [oso-polar]; Zanzibar/SpiceDB/OpenFGA [zanzibar2019, spicedb, openfga].

**Postgres-adjacent:** pgauthz/pg_cel [pgauthz, pg-cel]; pg_command_fw [pg-command-fw]; MCP DB tools [safe-postgres-mcp, pgguard-mcp, postgres-mcp-pro]; multi-tenant agent isolation [securing-the-agent-2026, supabase-agents, neon-rls]; AuthZEN PEP/PDP API [authzen].

We differ from Oracle Deep Data Security by targeting **Plane B on open Postgres** (tools, temporal, guidance, packs). We differ from Cedar/Dogwood by **co-location with RLS** and `CREATE EXTENSION` packaging—not by claiming faster row rewrites than a commercial engine.

---

## 10. Conclusions

Agents make the database a tool, not just a store. **Oracle Deep Data Security confirms** that vendors agree: identity-aware authorization must live in the database for agentic SQL. That is Plane A. Row security (Postgres RLS, Oracle DATA GRANT) remains mandatory and must be indexed. Tool/session policy does **not** belong in those row quals; it belongs in a **once-per-tool** evaluator beside the data—Plane B, where MCP gateways, export budgets, and guidance still lack a Postgres-native home.

pg_agent_policy is an existence proof for the open ecosystem: a Cedar/Dogwood-inspired dialect, SQL API, layered guardrails, and domain packs, with matcher costs negligible next to LLM loops and with expected-loss math that favors a last referee in PostgreSQL—provided the PEP calls `evaluate()` and RLS backs the row path.

**Industrial prescription:** GRANT + indexed RLS (or Oracle DATA GRANT on 26ai) for rows; APL `evaluate()` for tools and non-SQL MCP actions; model filters for text; shadow-mode for a week; then enforce. Do not accept “the database is too slow for policy” without asking *which plane* and *whether you indexed it*. On Oracle, adopt Deep Data Security for SQL identity; on Postgres, pair RLS with APL for the tool plane Oracle does not ship.

### Artifact

https://github.com/rahiakil/pg-policy — extension, packs, PEP middleware, experiments in `experiments/`.

---

## Appendix A — PEP snippet

```python
decision = evaluate(conn, agent_id="langgraph:analytics", tool="execute_sql",
                    context={"statement_type": kind, "tenant_id": tenant, "acting_for": user},
                    session_id=thread_id)
sql = apply_sql_obligations(sql, decision)  # honor max_rows
# then run SQL as agent_runtime (RLS still applies)
```

## Appendix B — Reproduction

```bash
cd experiments
python3 bench_evaluate.py      # Python oracle → results/evaluate_microbench.json
./bench_evaluate_pg.sh 16      # PL/pgSQL wall time → results/evaluate_pg_microbench.json
python3 cost_model.py          # → results/cost_model.json
```
