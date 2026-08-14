# Competitive Positioning & Moat Analysis

**Last updated:** 2026-08-10

---

## 1. Category creation

We are not competing as “yet another OPA.” We define:

**Database-resident agentic policy** — policy evaluation co-located with PostgreSQL for AI agents that read/write data and invoke tools.

Adjacent categories we borrow from:

- Policy-as-code (Cedar/Rego)
- Runtime verification for agents (Dogwood)
- Row-level security (Postgres)
- Authorization services (Oso, AuthZed, OpenFGA)

---

## 2. Differentiation matrix

| Capability | RLS | Dogwood/AgentCore | OPA | SpiceDB/OpenFGA | pg_agent_policy |
| --- | --- | --- | --- | --- | --- |
| Install with `CREATE EXTENSION` | built-in | no | no | no | **yes** |
| Tool-level permit/forbid | no | yes | yes | partial | **yes** |
| Soft guidance / obligations | no | limited | custom | no | **yes** |
| Session temporal in DB | no | yes (runtime) | custom | no | **yes** |
| Complements RLS recipes | n/a | external | external | external | **yes** |
| PGXN marketplace | n/a | no | no | no | **yes** |
| Works offline in VPC Postgres | yes | depends | yes | yes | **yes** |

---

## 3. Messaging pillars

1. **Beside the data** — policies, events, and rows share transactional integrity.
2. **Built for agents** — tools, sessions, guidance—not only tables.
3. **Postgres-native packaging** — extension, SQL API, PGXS, PGXN.
4. **Graduated enforcement** — log → guide → enforce.
5. **Open community standard** — PostgreSQL License, docs, tests, ADRs.

---

## 4. Anti-positioning (what we are not)

- Not a replacement for RLS.
- Not a general Kubernetes admission controller.
- Not a hosted authz SaaS (though compatible with gateways).
- Not a fork of Postgres with new SQL keywords.

---

## 5. Go-to-market sequence

1. Excellent GitHub + research docs (this repo).
2. Working SQL MVP + examples.
3. PGXN publish when API stabilizes (0.1.x).
4. Content: “RLS is not enough for agents.”
5. Partner conversations with MCP gateway authors.
6. Managed-provider extension programs.
