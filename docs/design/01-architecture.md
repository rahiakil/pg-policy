# Architecture

```text
┌──────────────────────────────────────────────────────────────────┐
│                         External world                           │
│  LLM agents · MCP tool brokers · app backends · SQL clients      │
└───────────────────────────────┬──────────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────┐
│ PostgreSQL                                                       │
│                                                                  │
│  ┌──────────────── pg_policy schema ─────────────────────────┐   │
│  │ policies │ sessions │ events │ decision_log │ settings    │   │
│  │                                                           │   │
│  │ parse_apl → IR                                            │   │
│  │ upsert_policy / drop_policy                               │   │
│  │ open_session / record_event                               │   │
│  │ evaluate / check / enforce                                │   │
│  └───────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────── data plane (existing) ────────────────────┐   │
│  │ roles · GRANT · RLS CREATE POLICY · FORCE RLS             │   │
│  └───────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

## Trust boundaries

1. **Policy admin** writes APL (privileged).
2. **Agent runtime role** calls `evaluate` / `check` (execute privilege only on functions + limited DML on events via functions).
3. **Data access** still constrained by GRANT + RLS.

Hardening grants for least privilege are documented as examples in later releases; v0.1 focuses on semantics.

## Decision algorithm (v0.1)

1. Load enabled policies matching principal/action/resource globs.
2. Filter by context predicates and temporal predicates.
3. Collect obligations from all matches.
4. If any `forbid` matched → deny candidate; else if `permit` or `guide` → allow; else default (`permit` setting).
5. Apply enforcement mode (`log_only` / `guide` / `enforce`).
6. Persist decision_log; optionally append session event.
