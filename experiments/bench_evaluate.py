#!/usr/bin/env python3
"""Microbenchmark the v0.1 APL matcher.

Reports p50/p95 latency for policy-set sizes typical of MCP gateways.
Does not include PostgreSQL function-call or network RTT (see cost_model.py).
"""

from __future__ import annotations

import json
import statistics
import time
from pathlib import Path

from policy_engine import Policy, baseline_pack, evaluate


def padded_pack(n: int) -> list[Policy]:
    policies = baseline_pack()
    while len(policies) < n:
        i = len(policies)
        policies.append(
            Policy(
                name=f"noise_{i}",
                effect="permit",
                action_id=f"unused_tool_{i}",
                priority=100 + i,
            )
        )
    return policies


def bench(n_policies: int, iters: int = 8000, warmup: int = 400) -> dict[str, float]:
    policies = padded_pack(n_policies)
    ctx = {"statement_type": "DROP", "tenant_id": "acme", "acting_for": "user:1"}
    kwargs = dict(
        principal_type="agent",
        principal_id="langgraph:analytics",
        action_type="tool",
        action_id="execute_sql",
        context=ctx,
        event_count=0,
        mode="enforce",
    )
    for _ in range(warmup):
        evaluate(policies, **kwargs)
    samples = []
    for _ in range(iters):
        t0 = time.perf_counter_ns()
        out = evaluate(policies, **kwargs)
        samples.append(time.perf_counter_ns() - t0)
        assert out["decision"] == "deny"
    samples.sort()

    def pct(p: float) -> float:
        idx = min(len(samples) - 1, int(p / 100.0 * (len(samples) - 1)))
        return samples[idx] / 1000.0  # ns -> µs

    return {
        "n_policies": n_policies,
        "iters": iters,
        "p50_us": round(pct(50), 3),
        "p95_us": round(pct(95), 3),
        "p99_us": round(pct(99), 3),
        "mean_us": round(statistics.mean(samples) / 1000.0, 3),
    }


def main() -> None:
    results = [bench(n) for n in (3, 10, 25, 50, 100, 200)]
    out = Path(__file__).parent / "results" / "evaluate_microbench.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"engine": "python-oracle-v0.1", "results": results}, indent=2))
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
