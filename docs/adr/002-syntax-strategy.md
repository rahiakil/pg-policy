# ADR-002: Syntax Strategy Without Parser Plugins

**Status:** Accepted  
**Date:** 2026-08-10

## Context

Users want “additional syntax for policy in Postgres.” Core Postgres does not allow extensions to modify SQL grammar.

## Decision

1. **Primary UX:** dollar-quoted APL passed to `pg_policy.upsert_policy`.
2. **Secondary UX:** JSONB structured policy insert for generated clients.
3. **Tertiary UX (roadmap):** hooks that enforce statement classes for agent roles.
4. **Non-goal:** Postgres fork or patch to add `CREATE AGENT POLICY` tokens.

Document the constraint honestly in README and design docs; still market APL as the extension’s policy syntax.

## Consequences

- Portable across PG versions and hosts that allow `CREATE EXTENSION`.
- Editor highlighting requires APL plugins (roadmap).
- Feels native via SQL functions, similar to many top extensions.
