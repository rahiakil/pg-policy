# Experiments for the industry paper

```bash
python3 bench_evaluate.py      # Python oracle → results/evaluate_microbench.json
./bench_evaluate_pg.sh 16      # PL/pgSQL wall time (needs Docker or local Postgres)
python3 cost_model.py          # → results/cost_model.json
```

Results: `results/evaluate_microbench.json`, `results/evaluate_pg_microbench.json` (after PG bench), `results/cost_model.json`.

The matcher is a Python oracle of `sql/pg_agent_policy--0.1.0.sql` semantics, not PostgreSQL SPI wall time. See `paper/README.md` for claims hygiene.

`bench_evaluate_pg.sh` loads extension DDL via `psql`, pads policies, and measures `evaluate()` + `decision_log` using `clock_timestamp()`. Use this for paper §6.2b numbers; do not cite Python-oracle µs as PostgreSQL latency.
