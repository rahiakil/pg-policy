# Use-case catalog

Each use case lists **who**, **what the agent does**, **what RLS cannot do alone**, the **pack to load**, and **success**. Packs live in [`examples/packs/`](../../examples/packs/).

---

## 1. Text-to-SQL analytics agent (BI copilot)

**Who:** data team, embedded SaaS analytics  
**Agent does:** natural language → `execute_sql` / `explain_query`  
**RLS gap:** cannot cap rows, block DDL, rate-limit exports, prefer EXPLAIN  
**Pack:** `analytics.sql`  
**Success:** zero cross-tenant rows (RLS) + zero DDL (APL) + exports ≤ N/hour + `max_rows` obligation honored by MCP

## 2. Customer-support copilot

**Who:** CX platform  
**Agent does:** read tickets/orders, draft replies, rare refunds  
**RLS gap:** refund is a *tool*, not a row; needs approval + session quota  
**Pack:** `support.sql`  
**Success:** PII export denied without `approved=true`; refund tool forbidden until temporal approval event

## 3. Fintech / payments operations agent

**Who:** banks, ledgers, finops  
**Agent does:** investigate transactions, propose journal entries, never settle without HITL  
**RLS gap:** SOX attribution, dual-control, amount thresholds  
**Pack:** `fintech.sql`  
**Success:** `acting_for` required in context; `transfer_funds` forbidden unless `formerly` approval (v0.1: approval flag + quota)

## 4. Healthcare chart / claims assistant

**Who:** HIPAA-covered entities  
**Agent does:** retrieve encounters, summarize, never bulk-export PHI  
**RLS gap:** unique user identification; minimum necessary; 6–7 year audit  
**Pack:** `healthcare.sql`  
**Success:** every evaluate logs human + agent; export_csv forbidden; decision_log retained

## 5. DevOps / DBA agent (dangerous by default)

**Who:** platform engineering  
**Agent does:** `EXPLAIN`, bloat reports, *proposed* migrations  
**RLS gap:** owner roles bypass RLS; DDL is the blast radius  
**Pack:** `devops.sql`  
**Success:** `CREATE/ALTER/DROP` forbidden in enforce; guide suggests migration PRs not live DDL

## 6. Multi-agent crew (researcher + writer + critic)

**Who:** CrewAI / LangGraph supervisor graphs  
**Agent does:** specialist agents share one database  
**RLS gap:** one DB role ≠ one agent identity  
**Pack:** `multi-agent.sql`  
**Success:** writer cannot `execute_sql`; researcher cannot `send_email`; supervisor can delegate only listed tools

## 7. RAG + SQL hybrid (knowledge + warehouse)

**Who:** enterprise search over docs *and* tables  
**Agent does:** `kb_search` then `execute_sql`  
**RLS gap:** retrieval filters ≠ SQL tool policy  
**Pack:** start from `analytics.sql` + forbid `kb_search` without `tenant_id` in context  
**Success:** both tools require the same tenant context key

## 8. Cursor / IDE coding agent on a live DB

**Who:** developers  
**Agent does:** schema inspect, sample rows, sometimes writes in dev  
**RLS gap:** laptop MCP with prod credentials  
**Pack:** `devops.sql` in prod (`enforce`); `analytics.sql` in staging (`guide`)  
**Success:** prod MCP cannot write; shadow logs in staging for a week

## 9. Nightly autonomous jobs (no human in the loop)

**Who:** batch agents  
**Agent does:** scheduled summaries, anomaly flags  
**RLS gap:** unbounded retries look like exfil  
**Pack:** baseline + tight temporal quotas  
**Success:** `count(action == "execute_sql") within interval '10 minutes' >= 50` forbids loops

## 10. Break-glass incident response

**Who:** SRE + security  
**Agent does:** nothing extra; humans override  
**RLS gap:** need an auditable exception, not a shared superuser  
**Pack:** `baseline.sql` + documented human role; never encode break-glass as `principal agent "*"` permit-all

---

## Mapping to planes

| Use case | Plane A (RLS) | Plane B (pg_agent_policy) | Plane C (model) |
| --- | --- | --- | --- |
| Analytics | tenant_id | DDL, row cap, export quota | hallucination SQL |
| Support | customer scope | refund tool, PII export | tone / secrets in reply |
| Fintech | account ownership | amount + approval | social engineering |
| Healthcare | patient panels | PHI export, attribution | diagnosis claims |
| DevOps | n/a / FORCE RLS | DDL firewall | “just run it” |
| Multi-agent | shared tenant | per-agent tool matrix | agent-to-agent prompt leak |

Onboard any of these with [`docs/onboarding/`](../onboarding/README.md).
