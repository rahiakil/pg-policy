# Policy Language Landscape for Database-Resident Enforcement

**Status:** living research  
**Last updated:** 2026-08-10  
**Scope:** Languages and engines that could inform (or be embedded in) a PostgreSQL extension for agentic AI policy.

---

## 1. Executive summary

Authorization and governance languages fall into four families:

| Family | Examples | Decision model | Fit for in-Postgres agent policy |
| --- | --- | --- | --- |
| Attribute / logic policy | Cedar, Rego (OPA), CEL, Sentinel | Evaluate rules against request attributes | High for point-in-time guardrails |
| Relationship / graph | Zanzibar, OpenFGA, SpiceDB, Keto | Walk stored relationship tuples | High for multi-tenant sharing; naturally DB-backed |
| Logic programming authz | Polar (Oso) | Query rules + facts | Medium–high; Oso already emits SQL fragments |
| Temporal / agent governance | Dogwood (Cedar + temporal) | Session history + permit/forbid | **Highest** for agentic sequences, budgets, prerequisites |

No mainstream language is *native* to PostgreSQL as an extension-authored grammar. Postgres RLS (`CREATE POLICY`) is the closest built-in, but it is row-scoped, statement-command scoped (`SELECT`/`INSERT`/…), and not designed for agent tool calls, soft guidance, or session-temporal constraints.

**Product implication:** Build a Postgres-resident **Agent Policy Language (APL)** that:

1. Complements RLS (data plane).
2. Covers agent/tool/session governance (control plane).
3. Offers enforce / log-only / guide modes.
4. Uses SQL-callable surfaces (Postgres cannot extend `gram.y`).

---

## 2. Built-in PostgreSQL policy surface

### 2.1 Row-Level Security (`CREATE POLICY`)

```sql
CREATE POLICY tenant_isolation ON orders
  FOR ALL
  TO agent_role
  USING (tenant_id = current_setting('app.tenant_id')::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id')::uuid);
```

**Strengths**

- Enforced inside the executor; cannot be bypassed by crafted `WHERE` clauses (for non-bypass roles).
- Familiar to Supabase, Neon Data API, PostgREST, Hasura users.
- Composes with `GRANT` (table privileges) and roles.

**Gaps for agentic AI**

- No first-class *agent* / *tool* / *session* principal model.
- No soft “guidance” outcomes (only allow/deny of rows).
- No temporal history (“approval happened in last hour”).
- No content/guardrail signals (PII score, prompt-injection score).
- Policy expressions are SQL booleans only—powerful but unstructured for product UX.
- Owners / `BYPASSRLS` / superusers bypass unless carefully configured (`FORCE ROW LEVEL SECURITY`).

### 2.2 Privileges, default privileges, SELinux (sepgsql)

Useful layers, but not a policy *language* for application/agent authors.

### 2.3 Event triggers & hooks

`ProcessUtility_hook`, `ExecutorStart_hook`, `planner_hook`, event triggers can *enforce* policy but do not define a human-authored DSL by themselves.

---

## 3. Attribute / logic policy languages

### 3.1 Cedar (AWS, open source)

- **Model:** `permit` / `forbid` over principal, action, resource; `when` / `unless` clauses.
- **Properties:** schema-typed, analyzable (decidable SMT fragment), deny-overrides, high performance.
- **Ecosystem:** Amazon Bedrock AgentCore Policy; Dogwood extends Cedar for agents.
- **Postgres fit:** Embed evaluator (Rust via pgrx) or compile Cedar → SQL predicates. Excellent readability for app/agent policies.
- **Limitation:** Stateless by design; no session history without an outer system (Dogwood).

### 3.2 Rego / Open Policy Agent (OPA)

- **Model:** Datalog-like rules over JSON input/data documents.
- **Strengths:** CNCF graduated, broad infra adoption, flexible structured output.
- **Weaknesses:** Steep learning curve; operational distribution of bundles; 2025 commercial uncertainty around Styra/enterprise path raised community questions (project remains open source).
- **Postgres fit:** `pgauthz`-style overlay (external OPA or embedded); or store Rego and call out. Heavier than Cedar for “policy as SQL neighbor.”

### 3.3 CEL (Common Expression Language)

- **Model:** Non-Turing-complete expressions over typed contexts (`request.*`, `resource.*`).
- **Strengths:** Familiar to Kubernetes/GCP users; safe evaluation; already used in `pgauthz` via `pg_cel`.
- **Postgres fit:** Excellent as *condition language* inside a larger policy object (ABAC predicates).
- **Limitation:** Not a full authz product language (no permit/forbid algebra, no ReBAC).

### 3.4 HashiCorp Sentinel

- **Model:** Policy-as-code for Terraform/Vault/Consul/Nomad.
- **Postgres fit:** Poor as an embed target; domain-locked to HashiCorp runtimes. Useful as *UX inspiration* for graded enforcement (`advisory` / `soft-mandatory` / `hard-mandatory`).

### 3.5 Other expression / rules engines

| Language | Notes |
| --- | --- |
| Open Policy Agent Gatekeeper ConstraintTemplates | K8s-specific |
| AWS IAM policy JSON | Action/resource/condition; verbose; not agent-session aware |
| XACML | Enterprise ABAC; heavy XML; rarely greenfield |
| SpEL / JSONata / JMESPath | Expression snippets, not full policy systems |

---

## 4. Relationship-based engines (Zanzibar family)

### 4.1 Model

Authorization is a graph of tuples:

```text
document:budget#viewer@user:alice
folder:reports#parent@folder:finance
```

Checks are reachability queries; list-objects is a first-class reverse query.

### 4.2 Implementations

- **OpenFGA** (CNCF incubating) — model DSL + conditions.
- **SpiceDB** (AuthZed) — Google Zanzibar-inspired, Postgres/Cockroach backends common.
- **Ory Keto** — Zanzibar-like API.

### 4.3 Postgres fit

Relationship stores *want* a database. An extension can:

1. Store tuples in tables and expose `check(user, relation, object)`.
2. Generate RLS predicates from relationship expansion (similar to Oso Local Authorization).
3. Combine ReBAC (who relates to what) with ABAC (under what attributes).

**Agent use:** “Can agent_A act as delegate of user_B on tenant_C?” is naturally ReBAC.

---

## 5. Polar (Oso)

- Logic language with actors, resources, roles, permissions, relations.
- **Local Authorization:** Oso can emit SQL fragments evaluated against your Postgres schema—strong signal that *policy → SQL* is a winning pattern.
- Polar itself is not typically embedded *inside* Postgres as an extension language; the pattern is “engine outside, SQL inside.”

---

## 6. Temporal / agent governance: Dogwood

Dogwood (AWS open source, 2026) extends Cedar with:

- `when temporal { … }` over session event history (`formerly`, `previous`, `since`, aggregations).
- Information providers / guardrails (content filters, etc.) as computed context.
- Compile-to-Cedar with runtime-filled `context.*` slots.

**Why it matters for this project**

Agentic systems fail policies that only answer “is this single tool call allowed?” They need:

- Prerequisites (approve before transfer).
- Rate / budget limits (N exports per hour).
- Ordering (read before write; search before mutate).
- Soft guidance (prefer tool A; warn on tool B).

Dogwood validates the *product category*. A Postgres extension that stores session events next to data—and evaluates temporal policy beside RLS—has a unique co-location advantage.

---

## 7. AuthZEN and interoperability

The OpenID AuthZEN effort standardizes authorization request/response shapes across engines. A Postgres policy extension should:

- Expose an evaluation API mappable to AuthZEN (`subject`, `action`, `resource`, `context` → decision + obligations).
- Remain usable from SQL, HTTP gateways, and MCP tool brokers.

---

## 8. Languages that can realistically live *inside* a Postgres extension

| Approach | Mechanism | True custom grammar? | Examples / precedents |
| --- | --- | --- | --- |
| SQL boolean policies | Native RLS | No (built-in) | Postgres |
| Stored DSL + evaluate() | Text/JSONB policies; PL/pgSQL, C, Rust evaluator | Surface via functions | Custom; `pg_durable` SQL DSL style |
| Expression embed | CEL/Cedar runtime in pgrx | No | `pg_cel`, hypothetical `pg_cedar` |
| Function API mimicking DDL | `SELECT policy.create(...)` | Feels native | Most extensions |
| `ProcessUtility_hook` | Intercept existing DDL | Cannot add tokens to `gram.y` | Timescale continuous aggregates pattern; `pg_command_fw` |
| Procedural languages | PL/v8, PL/Python for policy scripts | Dangerous if unrestricted | Rarely recommended for authz |

**Hard constraint (community consensus):** PostgreSQL’s parser is not extension-pluggable. “Additional syntax” in the marketplace sense means either (a) a DSL inside dollar-quoting evaluated by the extension, or (b) clever reuse of existing SQL DDL shapes with extension options/functions—not new keywords in core SQL.

---

## 9. Comparative decision matrix (agentic Postgres)

| Requirement | RLS | Cedar | Rego | CEL | OpenFGA | Dogwood | **pg_agent_policy (proposed)** |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Row isolation | ✓ | via app | via app | via app | via tuples | via app | ✓ complements RLS |
| Tool allow/deny | ✗ | ✓ | ✓ | partial | partial | ✓ | ✓ |
| Soft guidance | ✗ | ✗ | custom | ✗ | ✗ | partial | ✓ first-class |
| Temporal/session | ✗ | ✗ | custom | ✗ | ✗ | ✓ | ✓ DB-native events |
| Runs in Postgres | ✓ | embed | sidecar | embed | often uses PG store | external | ✓ |
| Analyzability | SQL-dependent | strong | medium | strong | model-based | Cedar+temporal | schema-validated APL |
| PGXN-distributable | n/a | possible | hard | possible | n/a | n/a | ✓ design goal |

---

## 10. Sources (selected)

- PostgreSQL documentation: Row Security Policies
- AWS Open Source Blog: *Introducing Dogwood: runtime verification for AI agents* (2026)
- Dogwood Policy Guide: temporal expressions
- Oso: *OPA vs Cedar vs Zanzibar* (2025)
- OpenFGA: Policy engines vs relationship engines
- pgauthz / pg_cel: in-database ABAC with optional CEL
- pg_trickle research: custom SQL syntax limits (`ProcessUtility_hook` vs `gram.y`)
- PGXN Meta Spec and publishing HOWTO
- Neon / Supabase agent + RLS guidance (2025–2026)

---

## 11. Conclusion for `pg_agent_policy`

The greenfield opportunity is **not** “another Rego in Postgres.” It is:

> A PostgreSQL-native agent policy layer that speaks a Cedar/Dogwood-inspired dialect, stores policies and session telemetry beside application data, evaluates guardrails and guidance at tool/data boundaries, and compiles hard constraints down to RLS/`GRANT` where possible.

That is the unique intersection of database co-location, agentic governance, and extension marketplace distribution.
