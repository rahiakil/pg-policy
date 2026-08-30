# Database Policy for Agents — industry-track working paper

**Affiliation:** Agentic Memory Foundation  
**Artifact:** [`pg_agent_policy`](https://github.com/rahiakil/pg-policy) PostgreSQL extension  
**Status:** working paper (not yet submitted)

## Venue plan

| Venue | Format | Why it fits | Timing |
| --- | --- | --- | --- |
| **CIDR 2027** (Amsterdam, 24–27 Jan 2027) | ≤6 pages ACM sigconf *including* refs | Systems architecture, risky ideas, experience | Near-term; one-paper limit |
| **VLDB 2027 Industrial Track** | ≤12 pages *excluding* refs; ≥1 industry author | Open-source industrial system + measurements | After CIDR decision |
| **SIGMOD 2027 Industrial Track** | ≤12 pages + refs; ≥1 industry author | Same | Do **not** dual-submit with VLDB |
| arXiv cs.DB | preprint | Community feedback while targeting CIDR | Anytime |

SIGMOD 2026 and VLDB 2026 industrial deadlines have already passed. **CIDR 2027 is the realistic first shot.** Cut the 12-page draft in this folder down to 6 pages (drop appendix-level survey rows, keep the three-plane model, SQL examples, and cost/latency section).

CIDR CFP: https://www.cidrdb.org/cidr2027/cfp.html  
VLDB 2026 industrial (template still valid): https://vldb.org/2026/?call-for-industrial-track=

## Files

| File | Role |
| --- | --- |
| [`db-policy-for-agents.md`](db-policy-for-agents.md) | Canonical working paper (readable on GitHub) |
| [`db-policy-for-agents.tex`](db-policy-for-agents.tex) | ACM sigconf draft for Overleaf / CIDR–VLDB |
| [`references.bib`](references.bib) | Bibliography |
| [`../experiments/`](../experiments/) | Matcher microbench + expected-cost model |

## Compile (Overleaf or local TeX Live)

```bash
pdflatex db-policy-for-agents
bibtex db-policy-for-agents
pdflatex db-policy-for-agents
pdflatex db-policy-for-agents
```

Use `\documentclass[sigconf]{acmart}` (included). Switch `\cidrtrue` in the tex file for a 6-page CIDR cut checklist.

## Claims hygiene

- Matcher latencies in §6.2 are a **Python oracle** of APL v0.1 semantics, not PostgreSQL `evaluate()` wall time.
- **PL/pgSQL wall time:** run `experiments/bench_evaluate_pg.sh` → `results/evaluate_pg_microbench.json`. Until CI installcheck runs this, the paper quotes a **0.8–1.5 ms** conservative envelope on the same connection.
- RLS slowdown numbers are from published community microbenchmarks (indexed ≈2% p95; unindexed 3–8×).
- Breach probabilities in the cost model are **sensitivity assumptions**, not actuarial rates. The paper argues *ratios*, not a specific dollar ROI.
- **Oracle Deep Data Security (26ai)** is surveyed as Plane A; pg_agent_policy targets Plane B on open Postgres.
