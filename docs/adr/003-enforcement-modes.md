# ADR-003: Graduated Enforcement Modes

**Status:** Accepted  
**Date:** 2026-08-10

## Context

Shipping hard-deny policies into production agent fleets is risky without observation. Dogwood/AgentCore and HashiCorp Sentinel both emphasize graded enforcement.

## Decision

Support three modes (GUC + per-policy override):

| Mode | Deny policies | Guide policies |
| --- | --- | --- |
| `log_only` | Log only | Log only |
| `guide` | Convert to advice | Return obligations |
| `enforce` | Block | Return obligations on allow |

Default for new installs: `log_only` (safe onboarding). Production recommendation: `enforce` after shadow period.

## Consequences

- Safer adoption curve.
- Slightly more complex evaluate() return type.
- Requires high-quality decision logging.
