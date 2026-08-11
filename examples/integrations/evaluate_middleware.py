"""Minimal PEP middleware: call pg_policy.evaluate before any agent tool.

Works with psycopg3. Copy into LangGraph ToolNode wrappers, MCP servers, or Flask/FastAPI gateways.

Fail-closed sentinels match the domain packs:
  acting_for / tenant_id missing → "unset"
  approved missing → "false"
"""

from __future__ import annotations

from typing import Any, Mapping

# pip install psycopg[binary]
import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb


class PolicyDenied(PermissionError):
    def __init__(self, payload: dict[str, Any]):
        super().__init__("; ".join(payload.get("reasons") or ["denied"]))
        self.payload = payload


def _sentinels(context: Mapping[str, Any] | None) -> dict[str, Any]:
    ctx = dict(context or {})
    ctx.setdefault("acting_for", "unset")
    ctx.setdefault("tenant_id", "unset")
    ctx.setdefault("approved", "false")
    return ctx


def evaluate(
    conn: psycopg.Connection,
    *,
    agent_id: str,
    tool: str,
    context: Mapping[str, Any] | None = None,
    session_id: str | None = None,
    resource_type: str = "*",
    resource_id: str = "*",
    raise_on_deny: bool = True,
) -> dict[str, Any]:
    ctx = _sentinels(context)
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            """
            SELECT pg_policy.evaluate(
              'agent', %s, 'tool', %s, %s, %s, %s::jsonb, %s, %s
            ) AS result
            """,
            (
                agent_id,
                tool,
                resource_type,
                resource_id,
                Jsonb(ctx),
                session_id,
                raise_on_deny,
            ),
        )
        row = cur.fetchone()
    payload = row["result"]
    if raise_on_deny and not payload.get("allowed", False):
        raise PolicyDenied(payload)
    return payload


def apply_sql_obligations(sql: str, payload: Mapping[str, Any]) -> str:
    """Honor max_rows for naive SELECT tools. Prefer AST injection in production."""
    max_rows = None
    for ob in payload.get("obligations") or []:
        if ob.get("type") == "max_rows":
            max_rows = int(ob.get("value"))
    if max_rows is None:
        return sql
    stripped = sql.rstrip().rstrip(";")
    if " limit " in stripped.lower():
        return sql
    return f"{stripped} LIMIT {max_rows}"


def open_session(
    conn: psycopg.Connection,
    session_id: str,
    agent_id: str,
    attributes: Mapping[str, Any] | None = None,
) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT pg_policy.open_session(%s, 'agent', %s, %s::jsonb)",
            (session_id, agent_id, Jsonb(dict(attributes or {}))),
        )


if __name__ == "__main__":
    import os

    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        open_session(conn, "demo-thread", "langgraph:analytics")
        decision = evaluate(
            conn,
            agent_id="langgraph:analytics",
            tool="execute_sql",
            context={"statement_type": "SELECT", "tenant_id": "acme", "acting_for": "user:42"},
            session_id="demo-thread",
            raise_on_deny=False,
        )
        print(decision)
