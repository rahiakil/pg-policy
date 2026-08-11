# Experiments for the industry paper

```bash
python3 bench_evaluate.py   # APL matcher microbench
python3 cost_model.py       # expected-loss vs latency tax
```

Results: `results/evaluate_microbench.json`, `results/cost_model.json`.

The matcher is a Python oracle of `sql/pg_policy--0.1.0.sql` semantics, not PostgreSQL SPI wall time. See `paper/README.md` for claims hygiene.
