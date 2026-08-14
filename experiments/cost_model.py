#!/usr/bin/env python3
"""Expected-cost model: latency tax vs. breach tax for agent DB access.

All dollar figures are order-of-magnitude planning numbers for an industry
paper, not a claim about a specific incident. Sources are cited in the paper.
"""

from __future__ import annotations

import json
from pathlib import Path


# Literature / industry anchors (see paper.bib)
CEDAR_US = 10.0  # typical Cedar eval microseconds (sub-10µs common)
ZANZIBAR_P95_MS = 10.0
OPA_MS = 1.0
CLOUD_PG_RTT_MS = 2.0  # same-AZ
CROSS_AZ_MS = 8.0
LLM_TOOL_LOOP_MS = 800.0  # one model step + tool
RLS_INDEXED_OVERHEAD_PCT = 0.02  # ~2% p95 in published 1M-row microbench
RLS_UNINDEXED_SLOWDOWN_X = 5.0  # 3–8× community reports

# pg_agent_policy v0.1: PL/pgSQL + JSONB. Conservative envelope until pgrx lands.
# Lower bound: python matcher + 0.3ms local function call.
# Upper bound: cold plan + audit insert on a remote primary.
PG_POLICY_LOCAL_MS = 0.4
PG_POLICY_SAME_CONN_MS = 0.8  # evaluate on the connection about to run SQL
PG_POLICY_PLUS_AUDIT_MS = 1.5


def expected_annual_loss(p_bypass: float, incidents_year: float, loss_usd: float) -> float:
    return p_bypass * incidents_year * loss_usd


def latency_tax_usd(
    extra_ms: float,
    tool_calls_per_day: float,
    value_per_cpu_hour: float = 0.12,
) -> float:
    """Rough compute tax of extra milliseconds (not user-perceived LLM time)."""
    hours = (extra_ms / 1000.0) * tool_calls_per_day * 365 / 3600.0
    return hours * value_per_cpu_hour


def main() -> None:
    # Scenario: 200 agents, 50 tool calls/agent/day = 10k calls/day
    calls_per_day = 10_000
    incidents_year = 4.0  # attempted cross-tenant or DDL incidents an org might see
    loss_cross_tenant = 250_000.0  # conservative incident response + notification

    rows = []
    architectures = [
        ("app_filter_only", 0.08, 0.05),  # 8% of agent SQL omits tenant predicate (industry folklore + MCP bypass class)
        ("mcp_regex_gateway", 0.02, 1.5),  # extra hop + still bypassable (COMMIT; DROP)
        ("opa_sidecar", 0.005, OPA_MS + CROSS_AZ_MS),
        ("pg_agent_policy_evaluate", 0.0005, PG_POLICY_SAME_CONN_MS),  # residual: superuser/BYPASSRLS misconfig
        ("pg_agent_policy_plus_rls", 0.0001, PG_POLICY_SAME_CONN_MS + 0.2),
    ]
    for name, p_bypass, extra_ms in architectures:
        rows.append(
            {
                "architecture": name,
                "p_bypass": p_bypass,
                "extra_ms_per_tool": extra_ms,
                "expected_loss_usd_year": round(
                    expected_annual_loss(p_bypass, incidents_year, loss_cross_tenant), 2
                ),
                "latency_tax_usd_year": round(latency_tax_usd(extra_ms, calls_per_day), 4),
                "extra_ms_vs_llm_loop_pct": round(100.0 * extra_ms / LLM_TOOL_LOOP_MS, 4),
            }
        )

    payload = {
        "assumptions": {
            "calls_per_day": calls_per_day,
            "incidents_year": incidents_year,
            "loss_usd_per_realized_bypass": loss_cross_tenant,
            "llm_tool_loop_ms": LLM_TOOL_LOOP_MS,
            "pg_agent_policy_same_conn_ms": PG_POLICY_SAME_CONN_MS,
            "rls_indexed_overhead_pct": RLS_INDEXED_OVERHEAD_PCT,
            "rls_unindexed_slowdown_x": RLS_UNINDEXED_SLOWDOWN_X,
        },
        "architectures": rows,
    }
    out = Path(__file__).parent / "results" / "cost_model.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2))
    print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()
