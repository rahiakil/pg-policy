# Agentic AI Guardrails, Guidance, and Database Policy

**Status:** living research  
**Last updated:** 2026-08-10

---

## 1. Why agents break classical authorization

Classical IAM answers: *May principal P perform action A on resource R right now?*

Agents additionally:

- Chain tools into workflows (search → read → transform → write → export).
- Operate with probabilistic plans (LLM may invent a tool call).
- Hold broad credentials if connected directly to SQL.
- Need *steering* (“prefer read replicas”; “summarize before export”), not only binary deny.
- Accumulate risk over a session (repeated PII exports; escalating privileges via confused deputy).

Therefore agent governance needs **three outcome classes**:

| Class | Meaning | Examples |
| --- | --- | --- |
| **Guardrail (hard)** | Must not proceed | Block `DROP`; block cross-tenant read; block tool after budget exhausted |
| **Guidance (soft)** | May proceed with obligations / advice | Prefer indexed query; warn on full table scan; suggest approval |
| **Telemetry** | Record for audit / training / evals | Decision logs; tool traces; policy coverage metrics |

---

## 2. Industry patterns (2025–2026)

### 2.1 Application / gateway guardrails

- LLM firewalls (prompt injection, topic allowlists).
- Tool brokers that authorize each MCP/tool invocation.
- Amazon Bedrock AgentCore Policy (Cedar) + Dogwood temporal policies.
- Datapace-style DB access gateways in front of production SQL.

### 2.2 Database-native controls

- Dedicated least-privilege roles for agents.
- RLS + `FORCE ROW LEVEL SECURITY`.
- Statement timeouts, `default_transaction_read_only`, connection GUCs.
- Supabase / Neon emphasizing RLS as the agent multi-tenant boundary.

### 2.3 Hybrid (recommended)

```text
LLM  →  Planner  →  Tool Gateway (pg_agent_policy.evaluate)
                         │
                         ├─ deny → return error + reason
                         ├─ guide → attach advice / rewrite suggestion
                         └─ allow → execute tool
                                      │
                                      └─ if SQL tool: RLS still applies
```

Co-locating policy with data reduces drift between “app thinks tenant is X” and “DB enforces tenant X.”

---

## 3. Policy concerns unique to agentic systems

### 3.1 Tool governance

- Allowlists / denylists per agent identity.
- Argument constraints (SQL statement type; max rows; path prefixes).
- Side-effect classes: read / write / admin / external_network.

### 3.2 Data exfiltration

- Column-level sensitive tags (PII, secrets).
- Export rate limits and destination allowlists.
- Result-size budgets per session.

### 3.3 Temporal / workflow

- Prerequisites: human approval before `transfer_funds`.
- Quotas: ≤ 3 `export_csv` per hour.
- Ordering: `get_schema` before `execute_sql`.
- Cooling off after repeated denials (abuse detection).

### 3.4 Delegation & confused deputy

- Agent acts on behalf of user U: ReBAC-style `agent#acts_as@user`.
- Downstream tools must see effective subject, not only agent service account.

### 3.5 Guidance / steering

Not authorization—**product control**:

- Prefer cheaper models / tools.
- Prefer cached retrieval.
- Require citation tool before answer finalization.
- Suggest breaking a large mutation into batches.

Guidance should be machine-readable obligations, e.g.:

```json
{
  "decision": "allow",
  "obligations": [
    {"type": "prefer_tool", "value": "sql_explain"},
    {"type": "max_rows", "value": 100},
    {"type": "advice", "value": "Run EXPLAIN before large SELECT"}
  ]
}
```

---

## 4. Mapping concerns → extension features

| Concern | `pg_agent_policy` feature |
| --- | --- |
| Tool allow/deny | APL `permit` / `forbid` on `tool:*` |
| Row isolation | Generate/attach RLS; document complement |
| Session quotas | Event log + temporal predicates |
| Soft steering | `guide` effect + obligations |
| Rollout safety | `enforce` / `log_only` / `guide_only` modes |
| Audit | `pg_agent_policy.decision_log` |
| Interop | AuthZEN-shaped JSON API |

---

## 5. Threat model (short)

| Threat | Mitigation |
| --- | --- |
| Agent ignores guidance | Enforce hard subset; gateway must hard-fail on deny |
| Agent uses owner/superuser role | Deploy checklist; reject `BYPASSRLS` agent roles |
| Policy admin compromised | Separate roles; signed policy bundles (roadmap) |
| Prompt injection → tool storm | Temporal rate limits; deny loops |
| Policy–RLS drift | Compile tests; CI policy packs |

---

## 6. What “excellent” looks like for builders

1. Policies in Git (`.apl` or SQL migrations).
2. Unit tests: given session trace + request → expected decision.
3. Shadow mode in production for N days.
4. Dashboards: deny reasons, obligation adherence, tenant incidents.
5. Escape hatches: break-glass role with mandatory audit.

---

## 7. Conclusion

For agentic AI, the winning Postgres extension is a **control plane beside the data plane**: guardrails that cannot be talked out of, guidance that steers tool choice, and temporal memory of what the agent already did—all queryable, testable, and distributable as open source.
