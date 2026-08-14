# Installing pg_agent_policy

## Prerequisites

- PostgreSQL 14 or newer
- Development files for that PostgreSQL (`postgresql-server-dev-*` / Xcode + Postgres.app / Postgres from Homebrew)
- GNU make
- `pg_config` on your `PATH`

## Build and install

```bash
make
make install
```

Then in each database:

```sql
CREATE EXTENSION pg_agent_policy;
```

## Verify

```sql
SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_agent_policy';
SELECT pg_agent_policy.parse_apl($apl$
permit
  principal agent "a"
  action tool "t"
$apl$);
```

## Uninstall

```sql
DROP EXTENSION pg_agent_policy CASCADE;
```

## Packaged installs

PGXN and OS packages are planned; see `docs/roadmap.md`.
