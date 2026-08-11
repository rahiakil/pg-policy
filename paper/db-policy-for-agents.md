# Policy Beside the Data: An In-Database Control Plane for Agentic Workloads

**Working paper — industry track (CIDR 2027 / VLDB–SIGMOD 2027)**  
Agentic Memory Foundation · artifact: [`pg_policy`](https://github.com/rahiakil/pg-policy)  
August 2026

---

## Abstract

AI agents have become a new class of database client: they invent SQL at runtime, chain tools through the Model Context Protocol (MCP), and often share a service account. Classical privileges and row-level security (RLS) answer *which rows*, but not *which tool, in which session, after which prior acts, with what soft guidance*. Industry has responded with sidecars (OPA/Cedar), relationship databases (Zanzibar/SpiceDB), and per-process MCP regex firewalls. We argue that for agent–data interaction the **database is the source of truth** and should host a complementary *tool/session* policy plane—not because every predicate belongs in a per-row `USING` clause, but because authorization that is not co-located with data *drifts*.

We survey equivalent mechanisms (Postgres/SQL Server RLS, Oracle VPD/RAS, IBM LBAC, Cedar, Dogwood, Rego, Polar, OpenFGA, pgauthz, statement firewalls) and show that **none** combine agent-native vocabulary, session-temporal constraints, soft guidance, and `CREATE EXTENSION` packaging. We present **pg_policy** and **APL**, a small total language evaluated inside PostgreSQL, with layered guardrails (GRANT → RLS → `evaluate()` → model filters). We separate two costs that the “it will slow queries” objection conflates: (1) **per-row RLS** on unindexed columns (3–8× in published pgbench, ≈2% p95 once indexed) versus (2) **once-per-tool** PDP evaluation (our APL matcher is 16–263 µs p50 for 3–200 policies in-process; a conservative same-connection PL/pgSQL+audit envelope is 0.8–1.5 ms, **&lt;0.2% of a typical 800 ms LLM tool loop**). A sensitivity cost model shows expected-loss ratios that dominate millisecond taxes under any plausible cross-tenant incident cost. The industrial recommendation is architectural, not religious: **index RLS for rows; evaluate APL for tools; never put tool policy in the hot row path.**

---

## 1. Introduction

PostgreSQL spent three decades optimizing for a human-shaped client: a role, a session, a handful of statements, intent that is mostly honest. Agentic systems invert that contract. A single user prompt can become schema discovery, multi-join SQL, CSV export, and a sibling agent’s email tool—none of which were reviewed by a developer. Retrieval-augmented generation (RAG) already taught the industry that *relevance is not authorization*. Tool-using agents expand the surface: autonomous schema discovery, SQL construction, writes, exports, and confused-deputy delegation [securing-the-agent-2026, aws-agent-mesh].

Two camps now argue past each other:

1. **Keep policy out of the database.** Authorization is an application concern; in-DB predicates (especially RLS) surprise the planner and “slow everything down.” Sidecars (OPA), Cedar services, and MCP process filters are the right PEP.
2. **The database is the last referee.** If the agent holds a connection string, any check that is not in the server can be walked around—exactly as forgotten `WHERE tenant_id = …` clauses have walked around application filters for twenty years.

Both are half right. The first camp is correct that **per-row policy on unindexed columns is expensive**. The second is correct that **agents will talk to the database**. The mistake is treating “policy in the database” as a single mechanism. We split the control plane:

| Plane | Question | Mechanism |
| --- | --- | --- |
| A — data isolation | Which rows/columns exist for this identity? | `GRANT` + RLS / VPD |
| B — agent/tool control | May this agent call this tool, given session history? | **APL / pg_policy `evaluate()`** |
| C — model/content | Is the prompt/output allowed? | Bedrock Guardrails, Llama Guard, … |

Plane B is what production MCP Postgres servers are reinventing in Node (read-only transactions, row caps, DDL regexes, denial logs) [safe-postgres-mcp, pgguard-mcp, postgres-mcp-pro]. Those are *policies*. They should be data, versioned next to RLS, evaluated in SQL, not unique snowflakes per gateway binary.

**Contributions.** (1) A survey of in-DB and adjacent policy technologies against agentic requirements. (2) APL and pg_policy as an industrial artifact: language, SQL API, packs, layered guardrails. (3) A cost/latency analysis that *disentangles* RLS row-path overhead from once-per-tool PDP cost, with a runnable matcher microbench and an expected-loss model. (4) An onboarding contract that works for MCP, LangGraph, CrewAI, and IDE agents.

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

We asked: *is there already an in-database agent policy language?* Short answer: **no complete equivalent**. Long answer: rich partials.

### 3.1 In-database row/column security (Plane A)

| System | Model | Agent-native? | Temporal / guidance? |
| --- | --- | --- | --- |
| PostgreSQL RLS | SQL boolean `USING` / `WITH CHECK` | No | No |
| Oracle VPD (`DBMS_RLS`) | Dynamic `WHERE`; column-relevant policies | No | No |
| Oracle RAS | Intended VPD successor | No | No |
| SQL Server RLS | Predicate functions | No | No |
| IBM DB2 LBAC | Labels on rows/columns | No | No |

These are the correct *row* plane. Oracle VPD’s lesson for agents is architectural: the engine rewrites statements so the client cannot forget the predicate [oracle-vpd]. Postgres RLS is the same idea with SQL-native policy objects [pg-rls]. None speak *tools* or *sessions*.

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

pgauthz is the strongest prior *in-PG authorization framework*. pg_policy is narrower and more opinionated: agent principals, MCP tool names, `guide` obligations, session event counts, policy packs, PGXN packaging.

### 3.5 MCP Postgres servers (Plane B reinvented in-process)

After the deprecated `@modelcontextprotocol/server-postgres` `COMMIT; DROP` class of bypasses, serious servers independently implemented: `BEGIN READ ONLY`, `statement_timeout`, row caps, AST/single-statement checks, audit of denials. That duplication is the industrial smell that a database-resident PDP should exist.

**Finding.** There is a crowded Plane A and a crowded sidecar Plane B. The empty cell is: **agent-native policy as a PostgreSQL extension**, with guidance and temporal session constraints, distributed like `pgvector`.

---

## 4. Layered guardrails (the architecture)

```text
 LLM / agent runtime (LangGraph, CrewAI, Cursor, …)
        │  Plane C: content filters (optional)
        ▼
 Tool gateway / MCP  ── pg_policy.evaluate()   Plane B (once per tool)
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

**Defense in depth if someone skips `evaluate()`:** read-only role, `default_transaction_read_only`, no `BYPASSRLS`, optional future `ProcessUtility_hook` (pg_command_fw-style) for DDL. pg_policy v0.1 does not yet install that hook; the paper treats it as Plane B′.

---

## 5. APL and pg_policy (the artifact)

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
CREATE EXTENSION pg_policy;
SELECT pg_policy.set_setting('enforcement_mode', 'log_only');  -- never start at enforce

SELECT pg_policy.upsert_policy('block_ddl', $apl$
forbid
  principal agent "langgraph:analytics"
  action tool "execute_sql"
  when { context.statement_type in ["DROP", "TRUNCATE", "ALTER", "CREATE"] }
  reason "No DDL"
$apl$);

SELECT pg_policy.open_session('thread-abc', 'agent', 'langgraph:analytics',
  '{"acting_for":"user:42","tenant_id":"acme"}'::jsonb);

SELECT pg_policy.evaluate(
  'agent', 'langgraph:analytics', 'tool', 'execute_sql',
  'table', 'public.orders',
  '{"statement_type":"DROP","acting_for":"user:42","tenant_id":"acme"}'::jsonb,
  'thread-abc'
);
-- { "decision":"allow", "obligations":[{"type":"shadow_deny",...}], "mode":"log_only" }

SELECT pg_policy.set_setting('enforcement_mode', 'enforce');
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

### 6.2 Experiment A — APL matcher microbench

We implemented a Python oracle of pg_policy v0.1 matching (`experiments/policy_engine.py`, `bench_evaluate.py`): glob on principal/action/resource, JSON condition `eq`/`in`, temporal count, deny-overrides. Workload: baseline pack (DDL forbid matches `statement_type=DROP`) padded with non-matching policies.

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

**What this is not.** It is not `SPI` / PL/pgSQL / WAL of `decision_log`. We therefore quote a **conservative envelope** for v0.1 in PostgreSQL on the *same connection* as the upcoming SQL: **0.8 ms** evaluate+log, **1.5 ms** with extra audit chatter. A pgrx/Cedar backend (roadmap) targets Cedar’s µs class [cedar2024]. Zanzibar’s published p95 &lt; 10 ms includes a global distributed graph [zanzibar2019]—a different problem.

### 6.3 Experiment B — latency vs the agent loop

Assume an 800 ms model+tool step (typical; often worse):

| Extra PDP | Added ms | % of LLM loop |
| --- | ---: | ---: |
| App `if` (no enforcement) | 0.05 | 0.006% |
| pg_policy same-conn (envelope) | 0.8 | **0.10%** |
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
| pg_policy evaluate | 0.05% | $500 | $0.10 | 0.10% |
| pg_policy + RLS | 0.01% | $100 | $0.12 | 0.13% |

\*CPU-hour tax of extra milliseconds at $0.12/h—intentionally showing that **compute tax is noise**.

If P(bypass) for “app only” is 1% instead of 8%, E[loss] is still $10k/yr vs sub-dollar latency tax. The inequality is robust. The industrial takeaway is not the exact dollars; it is that **breach expected value and planner-path RLS mistakes dwarf PDP microseconds**.

### 6.5 When in-DB policy *does* hurt (and what to do)

1. **Unindexed RLS** on large facts tables — index `tenant_id`; wrap GUCs in `(SELECT current_setting(...))`.
2. **Many OR-combined permissive policies** — planner pain [bytebase-rls]; prefer fewer, simpler RLS expressions.
3. **Non-LEAKPROOF functions** blocking qual pushdown — keep RLS predicates simple equality.
4. **Calling `evaluate()` inside a per-row SQL function** — **don’t**. That is putting Plane B on the Plane A path.
5. **Synchronous remote HTTP from a `SECURITY DEFINER` trigger** — don’t; that is the latency people imagine.

pg_policy’s API is deliberately a **tool-level function**, not a row trigger.

---

## 7. Value that is not latency

Co-location buys properties sidecars simulate poorly:

1. **One trust boundary** — the agent’s SQL and the decision share a cluster (and can share a transaction for “check then execute” if the PEP so wraps).
2. **No second source of tenant truth** — `context.tenant_id` can be the same GUC RLS reads.
3. **Session events next to data** — temporal quotas do not require a separate Redis.
4. **Audit queryability** — `SELECT * FROM pg_policy.decision_log WHERE reasons && ARRAY['No DDL']`.
5. **Pack portability** — the same APL loads in CI Postgres, on-prem, and (once allowlisted) Neon/RDS.
6. **Gateway independence** — swapping MCP servers does not rewrite policy.

These are why we call the database the source of truth: not because it must evaluate every boolean faster than Cedar, but because **the rows, the tenants, and the agent’s side effects already live there**.

---

## 8. Threats to validity

- Matcher bench is CPython, not PL/pgSQL; we therefore use a pessimistic PG envelope.
- P(bypass) is assumed; a red-team study of MCP bypass rates would strengthen the industrial claim.
- v0.1 APL is a small total language (no `formerly`/`since`, no SMT). Cedar/Dogwood remain stronger analyzers.
- Superusers still bypass RLS; we document this rather than pretend otherwise.
- Managed Postgres allowlists (Neon, RDS) currently block arbitrary extensions; PGXN is the open path, vendor programs are political.

---

## 9. Related work (short)

Authorization systems [zanzibar2019, cedar2024, opa, openfga, oso-polar]; DBMS security (RLS, VPD, LBAC); agent guardrail runtimes [dogwood2026]; MCP DB tools [safe-postgres-mcp, pgguard-mcp]; multi-tenant agent isolation [securing-the-agent-2026, supabase-agents, neon-rls]; AuthZEN PEP/PDP API [authzen]. We differ by **packaging Plane B as a PGXS extension with an agent-native dialect and packs**.

---

## 10. Conclusions

Agents make the database a tool, not just a store. Row security remains mandatory and must be indexed. Tool/session policy does **not** belong in those row quals; it belongs in a **once-per-tool** evaluator beside the data. pg_policy is an existence proof: a Cedar/Dogwood-inspired dialect, SQL API, layered guardrails, and domain packs, with matcher costs negligible next to LLM loops and with expected-loss math that favors a last referee in PostgreSQL.

**Industrial prescription:** GRANT + indexed RLS for rows; APL `evaluate()` for tools; model filters for text; shadow-mode for a week; then enforce. Do not accept “the database is too slow for policy” without asking *which plane* and *whether you indexed it*.

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
python3 bench_evaluate.py   # writes results/evaluate_microbench.json
python3 cost_model.py       # writes results/cost_model.json
```
