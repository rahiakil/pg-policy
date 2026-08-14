# Why databases must govern agents (and how pg_agent_policy does it)

**Audience:** database engineers, platform teams, agent-framework authors, security/compliance  
**Last updated:** 2026-08-10  
**Status:** public thesis

---

## 1. The shift nobody budgeted for

For thirty years, PostgreSQL assumed a **human-shaped client**: a role, a session, a few statements per second, intent that is mostly honest.

Agentic systems invert that:

| Human client | Agent client |
| --- | --- |
| One user, one app | One user → many agents → many tools |
| SQL written by a developer | SQL *invented* at runtime |
| Predictable statement mix | Tool storms, retries, fan-out |
| IAM + RLS is enough | IAM + RLS is necessary and **not sufficient** |
| Audit “who logged in” | Audit “which model, which tool, on whose behalf, after which prior acts” |

The industry already moved retrieval (RAG) behind metadata filters. **Tool-using agents expand the governance surface**: schema discovery, SQL construction, writes, exports, sibling agents, MCP brokers. AWS’s 2026 data-mesh guidance says it plainly: RAG needed one checkpoint; agents need a checkpoint at *every* data interaction.

Postgres is where those interactions become real. If policy does not live **beside the data**, every LangGraph graph, CrewAI crew, Cursor MCP, and homegrown SQL tool will reimplement a worse, drifting copy of the same rules.

That is the value of `pg_agent_policy`.

---

## 2. The three-plane model

```text
┌─────────────────────────────────────────────────────────────┐
│  Plane C — Model / content                                  │
│  Prompt injection filters, topic allowlists, PII redaction  │
│  (Bedrock Guardrails, NeMo, Llama Guard, …)                 │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│  Plane B — Agent / tool control   ← pg_agent_policy lives here    │
│  May this agent call this tool, with this context,          │
│  given this session history? Hard deny + soft guidance.     │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│  Plane A — Data isolation       ← Postgres RLS / GRANT      │
│  Which rows/columns exist for this tenant/user?             │
└─────────────────────────────────────────────────────────────┘
```

Most teams only build A (RLS) or only C (LLM firewalls). **B is the missing plane.** Without it:

- A read-only role still lets an agent `COPY` 40 million rows into a prompt.
- RLS still lets an agent call `export_csv` 200 times an hour.
- An MCP server that regex-blocks `DROP` still loses to `COMMIT; DROP…` (the deprecated reference Postgres MCP taught this the hard way).
- Multi-agent crews share one service account; nobody can answer “which agent did this?”

`pg_agent_policy` is plane B **inside PostgreSQL**, so A and B share transactions, catalogs, and audit.

---

## 3. What the research shows (2025–2026)

### 3.1 Relevance is not authorization

Enterprise RAG ranks by similarity, not permission. The 2026 work *Securing the Agent* (ACM) shows tool-mediated disclosure, context accumulation, and client-side orchestration bypass. Server-side ABAC at tool time eliminated cross-tenant leakage (~19 ms). That is the same job `evaluate()` does for SQL/MCP tools.

### 3.2 MCP servers are reinventing policy in process memory

Safe Postgres MCP implementations (`safe-postgres-mcp`, `pgguard-mcp`, Crystal DBA `postgres-mcp`) all independently add:

- read-only transactions
- statement timeouts
- row caps
- AST / single-statement checks
- denial audit logs

Those are **policy**. They should not be unique snowflakes per MCP binary. They should be data next to RLS, versioned in Git, evaluated in SQL.

### 3.3 Frameworks persist *in* Postgres but do not govern *through* it

LangGraph’s production pattern is `PostgresSaver` for graph checkpoints. CrewAI, AutoGen/AG2, Letta all speak MCP. **The state store is Postgres; the policy store is not.** That split is accidental, not architectural.

### 3.4 Regulation now expects an agent control plane

EU AI Act Article 12 (high-risk logging; widely cited full-enforcement milestone August 2026), GDPR accountability, HIPAA unique-user identification, SOC 2 monitoring, ISO/IEC 42001: logs must be structured, attributed (human + agent), correlated by session, and not “the LLM’s service account did something.” `pg_agent_policy.decision_log` + `sessions` + `events` are the database-shaped answer.

---

## 4. Value, stated as jobs-to-be-done

| Who | Job | How pg_agent_policy helps |
| --- | --- | --- |
| DBA / platform | Stop agents from DDL, COPY, superuser paths | `forbid` packs + least-privilege recipes |
| App security | One policy for every MCP/gateway | `evaluate()` as PDP; AuthZEN-shaped JSON |
| Agent engineer | Steer, don’t only block | `guide` obligations: `max_rows`, `prefer_tool`, `advice` |
| Compliance | Reconstruct a session | `decision_log` + temporal events |
| Multi-tenant SaaS | Tenant isolation *and* tool isolation | RLS (A) + APL (B) |
| Framework author | Don’t ship another regex firewall | Call SQL; inherit DB policy |

---

## 5. What “works for all” means

Not one mega-policy. A **universal kernel** plus **packs**:

1. **Kernel** — `CREATE EXTENSION`, `evaluate`, modes `log_only` → `guide` → `enforce`
2. **Identity convention** — `principal_type=agent`, id = framework agent name; `context.acting_for` = human user
3. **Tool vocabulary** — stable action ids (`execute_sql`, `explain_query`, `export_csv`, `list_tables`, …)
4. **Packs** — domain SQL you load in minutes (analytics, support, fintech, healthcare, devops, multi-agent)
5. **Adapters** — 15-line middleware for MCP / LangGraph / any HTTP PEP

If your agent can run SQL, it can call `pg_agent_policy.evaluate`. That is the compatibility story: **SQL is the lingua franca**, not another SDK.

---

## 6. Honest limits (trust is earned)

- APL v0.1 is a small total language, not Cedar’s SMT analyzer.
- Superusers and `BYPASSRLS` still bypass data-plane controls (Postgres fact).
- Default mode is `log_only` so you cannot surprise-deny production.
- This does not replace GRANT, RLS, network policy, or model guardrails.
- Managed clouds must allowlist the extension before `CREATE EXTENSION` works there.

Those limits are why we ship **shadow mode**, **packs**, and **RLS complements** instead of claiming a silver bullet.

---

## 7. Call to the database community

Postgres already won vectors, JSON, RLS, and (increasingly) agent *state*. The next primitive is **agent policy**. If we do not define it in-tree-as-extension, it will be defined in fifty incompatible MCP servers and three cloud consoles.

`pg_agent_policy` is that primitive: readable policy, session memory, guidance, audit — next to the rows agents actually touch.

**Read next:** [use cases](../usecases/README.md) · [onboarding](../onboarding/README.md) · [what to add next](08-capability-backlog.md) · [policy packs](../../doc/packs.md)
