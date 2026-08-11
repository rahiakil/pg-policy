# Roadmap

## Now (0.1.x)

- [x] Research: policy language landscape & agentic requirements
- [x] APL v0.1 + SQL catalog + evaluate/decision_log
- [x] Examples for guardrails, guidance, temporal, RLS complement
- [x] GitHub community standard files + META.json
- [ ] Expand regress tests; CI matrix PG 14–17
- [x] Use-case catalog, domain packs, universal onboarding, Python PEP
- [x] Value thesis + capability backlog for DB/agent audiences
- [ ] Continue industry analysis (managed provider allowlists, AuthZEN, MCP)

## Next (0.2.x)

- [ ] pgrx evaluator for performance and safer expression sandbox
- [ ] Optional CEL condition backend
- [ ] Richer temporal ops (`formerly`, `since`, sum)
- [x] Policy packs as versioned SQL scripts (v0.1); migration helper later

## Then (0.3.x)

- [ ] AuthZEN-shaped HTTP companion (optional, outside core)
- [ ] RLS helper generators from APL data policies
- [ ] Statement firewall via `ProcessUtility_hook` for agent roles
- [ ] Editor syntax highlighting for APL

## 1.0 / marketplace

- [ ] Stable APL grammar & IR
- [ ] Publish to [PGXN](https://pgxn.org/)
- [ ] Binary/OCI packaging track (PGXN v2)
- [ ] Submit to managed Postgres extension programs where applicable

## Non-goals

- Forking PostgreSQL to add core keywords
- Replacing RLS
- Executing untrusted Turing-complete policy scripts inside the server
