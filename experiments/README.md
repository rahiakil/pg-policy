# Experiments for pg_agent_policy

```bash
python3 bench_evaluate.py      # Python oracle → results/evaluate_microbench.json
./bench_evaluate_pg.sh 16      # PL/pgSQL wall time (needs Docker or local Postgres)
python3 cost_model.py          # → results/cost_model.json
```

Results: `results/evaluate_microbench.json`, `results/evaluate_pg_microbench.json` (after PG bench), `results/cost_model.json`.

The matcher is a Python oracle of `sql/pg_agent_policy--0.1.0.sql` semantics, not PostgreSQL SPI wall time. Paper and claims hygiene: [agentic-policy](https://github.com/Agentic-Memory-Foundation/agentic-policy).

`bench_evaluate_pg.sh` loads extension DDL via `psql`, pads policies, and measures `evaluate()` + `decision_log` using `clock_timestamp()`.
