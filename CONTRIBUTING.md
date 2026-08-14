# Contributing to pg_agent_policy

Thank you for helping build a PostgreSQL-native policy layer for agentic AI.

## Ways to contribute

- Bug reports and APL edge cases
- Example policy packs (fintech, support bots, analytics agents)
- Docs and research updates in `docs/research/`
- Tests under `test/`
- Performance / pgrx ports (coordinate via an issue first)

## Development setup

```bash
git clone https://github.com/rahiakil/pg-policy.git
cd pg-policy
# Requires PostgreSQL development packages and pg_config
make
make install
make installcheck   # when regress tests are configured against a live server
```

## Coding guidelines

- Prefer clear SQL and small pure helper functions.
- APL must remain **total** (no user-provided executable code in v0.x).
- Document security-sensitive changes in `SECURITY.md` / ADRs.
- Do not commit secrets, connection strings, or production policy dumps.

## Pull requests

1. Open an issue for larger design changes.
2. Keep PRs focused; update docs when behavior changes.
3. Add or adjust examples/tests for new APL features.
4. Use clear commit messages (why over what).

## Research contributions

Industry analysis is a first-class artifact. When you learn something material about Cedar, Dogwood, OPA, OpenFGA, managed Postgres extension allowlists, or MCP tool brokers, append a dated entry to `docs/research/04-industry-analysis.md`.

## Code of conduct

Please read [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
