# ADR-001: Agent Policy Language (APL) Design

**Status:** Accepted  
**Date:** 2026-08-10

## Context

We need a human-writable policy language for agentic guardrails that can be stored and evaluated inside PostgreSQL. Candidates: reuse Cedar text, Rego, CEL-only, Polar, or invent a thin dialect.

## Decision

Define **APL (Agent Policy Language)** as a *thin dialect*:

- Familiar `permit` / `forbid` / `guide` effects (Cedar + Sentinel guidance idea)
- Explicit `principal`, `action`, `resource` matching with optional wildcards
- `when { ... }` boolean conditions over JSON context (v0.1: JSONPath-like key checks via JSONB)
- Optional `when temporal { ... }` for session history (count/sum/exists within interval)
- `reason` string for humans and audit
- Policies named and versioned in catalog tables

v0.1 conditions are intentionally small and total (no loops, no user code). v0.2 may embed CEL/Cedar for richer expressions while keeping APL as the document format.

## Consequences

- Authors learn one small language optimized for agents.
- We do not inherit full Rego operational complexity.
- Cedar interop can be added later via import/export subset.
- Must document clearly that APL is not core SQL.
