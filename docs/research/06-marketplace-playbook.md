# Marketplace & Distribution Playbook

**Last updated:** 2026-08-10

## Phase 1 — GitHub excellence (done in 0.1.0)

- [x] README with clear problem, quick start, architecture
- [x] PostgreSQL License
- [x] CONTRIBUTING, CODE_OF_CONDUCT, SECURITY, SUPPORT, AUTHORS, Changes
- [x] META.json (PGXN Meta Spec 1.0)
- [x] Examples + research docs + ADRs
- [x] CI skeleton

## Phase 2 — Stabilize API

- Freeze `evaluate` JSON shape
- Add `expected` regress outputs and PG matrix CI
- Security review of `SECURITY DEFINER` (none in v0.1 by design)

## Phase 3 — PGXN publish

1. Create account on https://manager.pgxn.org/
2. `git archive` or zip distribution with `META.json` at root
3. Upload release; verify search indexing of README/docs
4. Announce on pgsql-announce / Discord / LinkedIn with “RLS is not enough for agents” narrative

## Phase 4 — Managed clouds

| Target | Action |
| --- | --- |
| Neon | Extension request + Discord; emphasize SQL-only safety |
| Supabase | Extension request; agent-focused positioning |
| RDS/Aurora | Long review; may need AWS partner path; consider pg_tle packaging experiment |
| Crunchy / Aiven / Timescale | Vendor conversations after PGXN traction |
| CloudNativePG | OCI trunk once PGXN v2 tooling ready |

## Phase 5 — Ecosystem

- AuthZEN HTTP adapter (optional companion repo)
- MCP reference middleware calling `pg_agent_policy.evaluate`
- Policy pack gallery (fintech, healthcare, support bots)
