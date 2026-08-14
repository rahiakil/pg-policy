# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| 0.1.x | Yes (experimental) |

## Security model (read this)

`pg_agent_policy` helps authorize agent/tool actions and record decisions. It is **not** a substitute for:

- PostgreSQL roles and `GRANT` / `REVOKE`
- Row Level Security for multi-tenant row isolation
- Network controls and credential hygiene
- A tool gateway that **hard-fails** on deny

Known limitations in v0.1:

- APL evaluator is PL/pgSQL (not a formally verified sandbox like Cedar)
- Superusers and `BYPASSRLS` roles can circumvent data-plane controls
- Default install mode is `log_only` — denials are shadowed until you enforce
- Do not store executable code inside policies

## Reporting a vulnerability

Please open a GitHub Security Advisory on https://github.com/rahiakil/pg-agent-policy or email the maintainers privately. Include:

1. PostgreSQL version and `pg_agent_policy` version
2. Minimal reproduction SQL
3. Impact assessment (authz bypass, DoS, injection, etc.)

We will acknowledge reports as quickly as practical and coordinate disclosure.
