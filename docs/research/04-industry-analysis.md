# Industry Analysis: Database Policy for Agentic AI

**Status:** living document — continuously updated  
**Last updated:** 2026-08-10  
**Cadence:** append dated entries; keep executive snapshot current

---

## Executive snapshot (2026-08)

| Trend | Evidence | Implication for pg_policy |
| --- | --- | --- |
| Agents get production DB credentials | Supabase Agents positioning; Neon Data API + RLS; multiple “safe SQL agent” posts | RLS alone is necessary but insufficient |
| Policy languages converge on Cedar-like readability | Cedar in AgentCore; Dogwood extends Cedar | APL should feel Cedar/Dogwood-familiar, SQL-native packaging |
| Temporal agent policy is newly mainstream | AWS Dogwood (2026) | Session event store inside Postgres is a differentiator |
| Gateways emerge in front of SQL | Datapace and similar control planes | Offer SQL-callable evaluate API for gateways *and* in-DB use |
| Extension distribution modernizing | PGXN v2, OCI trunks, CloudNativePG extension volumes | Ship classic PGXN first; track OCI later |
| ReBAC + ABAC hybrids | OpenFGA conditions; Oso local SQL | Support attributes now; relationships next |
| Observability of authz decisions | AuthZEN; decision logs in SaaS authz | First-class decision_log table |

---

## Market segments

### A. AI app platforms (Supabase, Neon, Firebase rivals)

Need: multi-tenant RLS + agent roles + easy policy recipes.  
pg_policy wedge: agent/tool policies + examples that compose with RLS.

### B. Enterprise agent platforms (Bedrock AgentCore, Azure AI, Vertex)

Need: Cedar/Dogwood-compatible governance, audit, temporal.  
pg_policy wedge: Postgres-resident evaluation for data tools; export/import Cedar subset (roadmap).

### C. MCP / tool gateway vendors

Need: per-tool authorize() with obligations.  
pg_policy wedge: single `evaluate()` returning AuthZEN-like decisions.

### D. Regulated industries (fintech, health, public sector)

Need: evidence of control, break-glass, retention.  
pg_policy wedge: immutable-ish decision logs; log_only → enforce promotion.

---

## Competitive landscape

| Player | Layer | Overlap | Gap we fill |
| --- | --- | --- | --- |
| Postgres RLS | DB | Row authz | No tools/temporal/guidance |
| OPA/Rego | Sidecar | General policy | Not PG-native DX |
| Cedar + Dogwood | Agent runtime | Agent temporal | Not co-located with SQL/RLS |
| OpenFGA/SpiceDB | Authz service | Relationships | Separate system to operate |
| Oso Cloud | AaaS | Polar + local SQL | External dependency |
| pgauthz | In-PG authz | ABAC/CEL | Not agent/guidance specialized |
| pg_command_fw | Hook firewall | DDL blocking | No policy language |
| Commercial DB gateways | Proxy | Statement control | Vendor lock-in; not extension |

**Positioning statement**

> pg_policy is the open-source PostgreSQL extension that adds an agentic policy language beside your data—guardrails, guidance, and session-aware limits—complementing RLS and publishing on PGXN for every Postgres.

---

## Adoption drivers & blockers

**Drivers**

- Fear of autonomous `DELETE`/`COPY`/exfil.
- MCP proliferating DB tools.
- Compliance asking “show me agent controls.”
- Developer preference for SQL-adjacent config.

**Blockers**

- Extension allowlists on managed Postgres.
- Learning yet another policy dialect.
- Performance anxiety on evaluate() hot paths.
- Confusion with RLS.

**Mitigations**

- Pure SQL v0.1 install path.
- Familiar permit/forbid/guide lexicon.
- Benchmarks + IR caching roadmap.
- Docs that teach “RLS for rows, pg_policy for agent actions.”

---

## Pricing / OSS strategy (pre-marketplace)

1. **Core OSS (PostgreSQL License):** language, evaluate, event log, RLS helpers.
2. **Later commercial-adjacent (optional, not now):** hosted policy studio, cross-cluster packs—only if community thrives; keep extension useful alone.
3. **PGXN** as primary discovery; GitHub as collaboration hub.

---

## Dated research log

### 2026-08-10 — Initial sweep

Completed landscape of Cedar, Rego, CEL, Polar, Zanzibar/OpenFGA, Dogwood, RLS, pgauthz, pg_cel, pg_command_fw, PGXN packaging constraints, and agent DB access literature (Supabase, Neon, Datapace, datamcp).

**Decision:** proceed with APL inside `pg_policy`, SQL-first MVP, Dogwood-inspired temporal + Sentinel-inspired graded modes (enforce/log/guide).

### 2026-08-10 — Managed provider distribution paths

| Provider | Model | Path for pg_policy |
| --- | --- | --- |
| **Self-hosted / PGXN** | Install any extension | Primary day-1 channel |
| **AWS RDS / Aurora** | Curated extension list + `rds.allowed_extensions` | Must be accepted by AWS into supported extensions; SQL-only helps review |
| **Neon** | Strict allow-list; request via support/Discord; no arbitrary C uploads; pg_tle not supported | Need Neon “request an extension”; popularity + safety story matter |
| **Supabase** | Allow-list (~64+); request process | Same: community traction → vendor packaging |
| **Aiven / Crunchy / Timescale** | Vendor-curated | Partner after OSS proof |
| **CloudNativePG + OCI trunks** | Emerging PGXN v2 / ImageVolume pattern | Medium-term binary distribution |

**Strategic implication:** SQL/PL/pgSQL v0.1 maximizes reviewability for allow-lists. Avoid requiring `shared_preload_libraries` until hook-based firewalls are optional. Track **Trusted Language Extensions (`pg_tle`)** only where hosts support it (RDS has been a notable TLE venue; Neon currently does not).

### 2026-08-10 — AuthZEN mapping sketch

OpenID **AuthZEN Authorization API 1.0** standardizes PEP↔PDP JSON:

| AuthZEN | pg_policy.evaluate |
| --- | --- |
| `subject.type` / `subject.id` | `p_principal_type` / `p_principal_id` |
| `action.name` (plus properties) | `p_action_type` + `p_action_id` (split for tool taxonomy) |
| `resource.type` / `resource.id` | `p_resource_type` / `p_resource_id` |
| `context` | `p_context` jsonb |
| `decision` boolean | `allowed` |
| context/obligations in richer PDPs | `obligations` array (guidance) |

Roadmap: optional thin HTTP PDP that translates AuthZEN → SQL `evaluate()` so MCP gateways can treat Postgres as a standards-shaped PDP without learning APL first.

### Next analysis probes

- [x] Survey managed Postgres providers’ extension allowlist processes (initial pass: RDS, Neon, Supabase, Aiven/Crunchy, CNPG/OCI).
- [ ] Benchmark CEL vs pure SQL IR for 10k evaluate/s.
- [x] Map AuthZEN request fields to `pg_policy.evaluate` JSON (sketch).
- [ ] Interview-style synthesis: MCP DB tool schemas (Cursor, Claude, LangChain SQL tool).
- [ ] Track PGXN v2 trunk/OCI readiness for binary distribution.
- [ ] Deep-dive `pg_tle` viability as alternate packaging for RDS-class hosts.
- [ ] Competitive watch: Dogwood releases, AgentCore Policy features, pgauthz CEL roadmap.

---

## Metrics to watch (project health)

| Metric | Target (90 days) |
| --- | --- |
| GitHub stars / meaningful issues | Community signal |
| Example policy packs | ≥ 5 domains |
| Compatible PG majors | 14–17 (then 18) |
| Time-to-first-policy from README | < 10 minutes |
| Decision log completeness | 100% of evaluate() calls |
