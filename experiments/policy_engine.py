"""Faithful v0.1 APL matcher (mirrors sql/pg_policy--0.1.0.sql semantics).

Used for microbenchmarks when a live PostgreSQL is unavailable, and as an
oracle for expected decisions.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class Policy:
    name: str
    effect: str  # permit | forbid | guide
    principal_type: str = "agent"
    principal_id: str = "*"
    action_type: str = "tool"
    action_id: str = "*"
    resource_type: str = "*"
    resource_id: str = "*"
    condition: dict[str, Any] = field(default_factory=dict)
    temporal: dict[str, Any] | None = None
    obligations: list[dict[str, Any]] = field(default_factory=list)
    reason: str | None = None
    priority: int = 100


def glob_match(pattern: str, value: str) -> bool:
    return pattern == "*" or pattern == value


def condition_holds(condition: dict[str, Any], context: dict[str, Any]) -> bool:
    if not condition:
        return True
    for key, spec in condition.items():
        op = spec.get("op")
        expected = spec.get("value")
        ctx_val = context.get(key)
        if op == "eq":
            if str(ctx_val) != str(expected):
                return False
        elif op == "in":
            if str(ctx_val) not in [str(x) for x in expected]:
                return False
        else:
            return False
    return True


def temporal_holds(temporal: dict[str, Any] | None, event_count: int) -> bool:
    if not temporal:
        return True
    if temporal.get("op") != "count":
        return False
    cmp_op = temporal.get("cmp", ">=")
    need = int(temporal.get("value", 0))
    if cmp_op == ">=":
        return event_count >= need
    if cmp_op == ">":
        return event_count > need
    return False


def evaluate(
    policies: list[Policy],
    *,
    principal_type: str,
    principal_id: str,
    action_type: str,
    action_id: str,
    resource_type: str = "*",
    resource_id: str = "*",
    context: dict[str, Any] | None = None,
    event_count: int = 0,
    default_decision: str = "deny",
    mode: str = "enforce",
) -> dict[str, Any]:
    ctx = context or {}
    matched: list[Policy] = []
    for p in sorted(policies, key=lambda x: (x.priority, x.name)):
        if not (
            glob_match(p.principal_type, principal_type)
            and glob_match(p.principal_id, principal_id)
            and glob_match(p.action_type, action_type)
            and glob_match(p.action_id, action_id)
            and glob_match(p.resource_type, resource_type)
            and glob_match(p.resource_id, resource_id)
            and condition_holds(p.condition, ctx)
            and temporal_holds(p.temporal, event_count)
        ):
            continue
        matched.append(p)

    has_forbid = any(p.effect == "forbid" for p in matched)
    has_permit = any(p.effect == "permit" for p in matched)
    has_guide = any(p.effect == "guide" for p in matched)
    decision = default_decision
    if has_forbid:
        decision = "deny"
    elif has_permit or has_guide:
        decision = "allow"

    obligations: list[dict[str, Any]] = []
    for p in matched:
        obligations.extend(p.obligations)

    if decision == "deny" and mode in ("log_only", "guide"):
        decision = "allow"
        obligations.append({"type": "shadow_deny" if mode == "log_only" else "would_deny", "value": True})

    return {
        "decision": decision,
        "allowed": decision == "allow",
        "matched": [p.name for p in matched],
        "obligations": obligations,
        "mode": mode,
    }


def baseline_pack() -> list[Policy]:
    return [
        Policy(
            name="pack_baseline_ddl",
            effect="forbid",
            action_id="execute_sql",
            condition={"statement_type": {"op": "in", "value": ["DROP", "TRUNCATE", "ALTER", "CREATE", "GRANT", "REVOKE"]}},
            reason="no ddl",
            priority=10,
        ),
        Policy(
            name="pack_baseline_sql_guide",
            effect="guide",
            action_id="execute_sql",
            obligations=[{"type": "max_rows", "value": 500}, {"type": "prefer_tool", "value": "explain_query"}],
            priority=80,
        ),
        Policy(
            name="pack_baseline_export",
            effect="forbid",
            action_id="export_csv",
            temporal={"op": "count", "cmp": ">=", "value": 5},
            reason="export budget",
            priority=20,
        ),
    ]
