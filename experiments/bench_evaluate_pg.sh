#!/usr/bin/env bash
# Measure pg_agent_policy.evaluate() wall time inside PostgreSQL (Docker).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-16}"
CONTAINER="pg-policy-bench-$$"
PORT=55432
ITERS="${ITERS:-1500}"
WARMUP="${WARMUP:-150}"
OUT="$ROOT/experiments/results/evaluate_pg_microbench.json"

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

mkdir -p "$ROOT/experiments/results"

docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=bench -p "$PORT:5432" "postgres:$TAG" >/dev/null
for _ in $(seq 1 90); do
  docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$CONTAINER" pg_isready -U postgres

# Load extension DDL (skip psql guard lines)
tail -n +3 "$ROOT/sql/pg_agent_policy--0.1.0.sql" | docker exec -i "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -q

docker exec -i "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -q <<'SQL'
SELECT pg_agent_policy.set_setting('enforcement_mode', 'enforce');
SELECT pg_agent_policy.upsert_policy('block_ddl', $apl$
forbid
  principal agent "langgraph:analytics"
  action tool "execute_sql"
  when { context.statement_type in ["DROP", "TRUNCATE", "ALTER", "CREATE"] }
  reason "No DDL"
$apl$);
SELECT pg_agent_policy.open_session('bench-sess', 'agent', 'langgraph:analytics',
  '{"acting_for":"user:42","tenant_id":"acme"}'::jsonb);
SQL

bench_one() {
  local n="$1"
  docker exec -i "$CONTAINER" psql -U postgres -At -v ON_ERROR_STOP=1 <<SQL
DO \$\$
DECLARE
  i int;
  t0 timestamptz;
  t1 timestamptz;
  deltas double precision[] := '{}';
  p50 double precision;
  p95 double precision;
  p99 double precision;
BEGIN
  DELETE FROM pg_agent_policy.policies WHERE name LIKE 'bench_pad_%';
  FOR i IN 1..GREATEST(0, ${n} - 1) LOOP
    PERFORM pg_agent_policy.upsert_policy('bench_pad_' || i, \$apl\$
forbid
  principal agent "pad:agent-" || i
  action tool "refund"
  when { context.amount in ["999999"] }
  reason "pad"
\$apl\$);
  END LOOP;

  FOR i IN 1..${WARMUP} LOOP
    PERFORM pg_agent_policy.evaluate(
      'agent','langgraph:analytics','tool','execute_sql','table','public.orders',
      '{"statement_type":"DROP","acting_for":"user:42","tenant_id":"acme"}'::jsonb,
      'bench-sess');
  END LOOP;

  FOR i IN 1..${ITERS} LOOP
    t0 := clock_timestamp();
    PERFORM pg_agent_policy.evaluate(
      'agent','langgraph:analytics','tool','execute_sql','table','public.orders',
      '{"statement_type":"DROP","acting_for":"user:42","tenant_id":"acme"}'::jsonb,
      'bench-sess');
    t1 := clock_timestamp();
    deltas := array_append(deltas, EXTRACT(EPOCH FROM (t1 - t0)) * 1000000.0);
  END LOOP;

  SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY v),
         percentile_cont(0.95) WITHIN GROUP (ORDER BY v),
         percentile_cont(0.99) WITHIN GROUP (ORDER BY v)
    INTO p50, p95, p99
    FROM unnest(deltas) AS v;

  RAISE NOTICE 'RESULT policies=% p50=% p95=% p99=%', ${n}, round(p50::numeric,1), round(p95::numeric,1), round(p99::numeric,1);
END \$\$;
SQL
}

echo "PostgreSQL $TAG evaluate() microbench (iters=$ITERS)..."

RESULTS="["
first=1
for n in 3 10 25 50 100; do
  line=$(docker exec -i "$CONTAINER" psql -U postgres -At 2>&1 <<SQL | grep '^RESULT' | tail -1
DO \$\$
DECLARE
  i int; t0 timestamptz; t1 timestamptz;
  deltas double precision[] := '{}';
  p50 double precision; p95 double precision; p99 double precision;
BEGIN
  DELETE FROM pg_agent_policy.policies WHERE name LIKE 'bench_pad_%';
  FOR i IN 1..GREATEST(0, ${n} - 1) LOOP
    PERFORM pg_agent_policy.upsert_policy('bench_pad_' || i, \$apl\$
forbid
  principal agent "pad:agent-" || i
  action tool "refund"
  when { context.amount in ["999999"] }
  reason "pad"
\$apl\$);
  END LOOP;
  FOR i IN 1..${WARMUP} LOOP
    PERFORM pg_agent_policy.evaluate('agent','langgraph:analytics','tool','execute_sql','table','public.orders',
      '{"statement_type":"DROP","acting_for":"user:42","tenant_id":"acme"}'::jsonb,'bench-sess');
  END LOOP;
  FOR i IN 1..${ITERS} LOOP
    t0 := clock_timestamp();
    PERFORM pg_agent_policy.evaluate('agent','langgraph:analytics','tool','execute_sql','table','public.orders',
      '{"statement_type":"DROP","acting_for":"user:42","tenant_id":"acme"}'::jsonb,'bench-sess');
    t1 := clock_timestamp();
    deltas := array_append(deltas, EXTRACT(EPOCH FROM (t1 - t0)) * 1000000.0);
  END LOOP;
  SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY v),
         percentile_cont(0.95) WITHIN GROUP (ORDER BY v),
         percentile_cont(0.99) WITHIN GROUP (ORDER BY v)
    INTO p50, p95, p99 FROM unnest(deltas) AS v;
  RAISE NOTICE 'RESULT policies=% p50=% p95=% p99=%', ${n}, round(p50::numeric,1), round(p95::numeric,1), round(p99::numeric,1);
END \$\$;
SQL
)
  # Parse: RESULT policies=25 p50=... p95=... p99=...
  p50=$(echo "$line" | sed -n 's/.*p50=\([0-9.]*\).*/\1/p')
  p95=$(echo "$line" | sed -n 's/.*p95=\([0-9.]*\).*/\1/p')
  p99=$(echo "$line" | sed -n 's/.*p99=\([0-9.]*\).*/\1/p')
  if [ -n "$p50" ]; then
    [ "$first" -eq 1 ] || RESULTS+=","
    first=0
    RESULTS+="{\"policies\":$n,\"p50_us\":$p50,\"p95_us\":$p95,\"p99_us\":$p99}"
    echo "  n=$n  p50=${p50}µs  p95=${p95}µs  p99=${p99}µs"
  fi
done
RESULTS+="]"

cat > "$OUT" <<EOF
{
  "engine": "postgresql-plpgsql-v0.1",
  "postgres_version": "$TAG",
  "iterations": $ITERS,
  "warmup": $WARMUP,
  "workload": "block_ddl match + padded non-matching policies",
  "results": $RESULTS
}
EOF

echo "Wrote $OUT"
