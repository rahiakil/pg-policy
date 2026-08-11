# Integration snippets

| File | Use |
| --- | --- |
| `evaluate_middleware.py` | PEP for any Python agent (LangGraph, MCP, FastAPI) |

Pattern:

```python
from evaluate_middleware import evaluate, apply_sql_obligations, PolicyDenied, open_session

open_session(conn, thread_id, "langgraph:analytics", {"acting_for": user_id})
decision = evaluate(conn, agent_id="langgraph:analytics", tool="execute_sql",
                    context={"statement_type": kind, "tenant_id": tenant, "acting_for": user_id},
                    session_id=thread_id)
sql = apply_sql_obligations(sql, decision)
# then run SQL as agent_runtime (RLS still applies)
```

See [`docs/onboarding/integrations.md`](../../docs/onboarding/integrations.md).
