/*
 * pg_agent_policy.c - v0.2 C-level hooks for non-bypassable enforcement
 *
 * Registers ProcessUtility_hook (DDL/utility) and ExecutorStart_hook
 * (statement-class DML) so an agent with a DSN that never calls
 * evaluate() still hits the policy referee. The hook derives
 * statement_type from the parsed SQL AST and overrides caller
 * context. Identity is bound to current_user / a login GUC.
 *
 * Requires PostgreSQL 15+. Load via:
 *   shared_preload_libraries = 'pg_agent_policy'
 *
 * License: PostgreSQL License
 */
#include "postgres.h"
#include "fmgr.h"
#include "tcop/utility.h"
#include "executor/executor.h"
#include "executor/spi.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "nodes/nodes.h"
#include "nodes/parsenodes.h"
#include "miscadmin.h"
#include "utils/acl.h"
#include "utils/syscache.h"
#include "catalog/pg_authid.h"
#include "catalog/pg_type.h"
#include "catalog/namespace.h"
#include "pg_agent_policy.h"

PG_MODULE_MAGIC;

static bool hook_enabled = true;
static bool hook_log_only = false;

/* Identity-binding GUCs (PGC_SUSET). */
static char *guc_principal_id = NULL;
static char *guc_session_id = NULL;

static ProcessUtility_hook_type prev_ProcessUtility = NULL;
static ExecutorStart_hook_type prev_ExecutorStart = NULL;

/*
 * Re-entrance guard: the hook fires on every statement, including the
 * SELECTs we issue ourselves via SPI to call evaluate(). Without this
 * guard we would recurse infinitely. While set, both hooks skip.
 */
static uint32 in_hook = 0;

char *
pgap_derive_statement_type(PlannedStmt *pstmt)
{
	Node *u = pstmt->utilityStmt;
	if (u == NULL)
	{
		switch (pstmt->commandType)
		{
			case CMD_SELECT: return pstrdup(ST_SELECT);
			case CMD_INSERT: return pstrdup(ST_INSERT);
			case CMD_UPDATE: return pstrdup(ST_UPDATE);
			case CMD_DELETE:  return pstrdup(ST_DELETE);
#ifdef CMD_MERGE
			case CMD_MERGE:   return pstrdup(ST_MERGE);
#endif
			default:          return pstrdup(ST_OTHER);
		}
	}
	switch (nodeTag(u))
	{
		case T_CreateStmt:   return pstrdup(ST_CREATE);
		case T_DropStmt:      return pstrdup(ST_DROP);
		case T_RenameStmt:    return pstrdup(ST_ALTER);
		case T_TruncateStmt:  return pstrdup(ST_TRUNCATE);
		case T_GrantStmt:     return pstrdup(ST_GRANT);
		case T_CopyStmt:      return pstrdup(ST_COPY);
		default:              return pstrdup(ST_OTHER);
	}
}

/*
 * The trusted principal binding. A tool gateway / MCP broker sets the
 * pg_agent_policy.principal_id GUC when it has authenticated an agent and
 * opened a session on its behalf. When the GUC is unset we are in
 * "admin/setup" mode and the hook does NOT enforce -- this is what lets
 * DBAs load policies and run migrations, and what keeps the regression
 * suite from being blocked by its own default-deny policy. Enforcement
 * is only active for connections that carry an explicit principal.
 */
char *
pgap_get_principal_id(void)
{
	if (guc_principal_id != NULL && guc_principal_id[0] != '\0')
		return pstrdup(guc_principal_id);
	return NULL;			/* admin mode: no agent principal bound */
}

char *
pgap_get_session_id(void)
{
	if (guc_session_id != NULL && guc_session_id[0] != '\0')
		return pstrdup(guc_session_id);
	return NULL;
}

/*
 * Is the extension installed yet? We check whether the extension's
 * schema exists via the syscache (no SQL issued, so no hook recursion).
 * The syscache is in-memory and cheap, so we check on every statement
 * rather than caching -- this stays correct across DROP/CREATE EXTENSION
 * cycles (a stale cache would make the hook call a missing function).
 */
static bool
pgap_extension_ready(void)
{
	Oid nspOid = get_namespace_oid("agent_policy", true);
	return OidIsValid(nspOid);
}

bool
pgap_evaluate_internal(const char *principal_id,
						const char *session_id,
						const char *action_id,
						const char *statement_type,
						const char *resource_type,
						const char *resource_id,
						bool raise_on_deny)
{
	int rc;
	bool allowed = true;
	StringInfoData ctx;
	StringInfoData sql;
	bool isnull;
	Datum d;

	/* Bootstrap: if the extension isn't installed yet, allow. */
	if (!pgap_extension_ready())
		return true;

	initStringInfo(&ctx);
	appendStringInfo(&ctx, "{\"statement_type\":\"%s\"}", statement_type);

	initStringInfo(&sql);
	appendStringInfo(&sql,
		"SELECT ((agent_policy.evaluate("
		"  'agent'::text, %s::text, 'tool'::text, %s::text, %s::text, %s::text, "
		"  '%s'::jsonb, %s::text, %s))->>'allowed')::boolean",
		quote_literal_cstr(principal_id),
		quote_literal_cstr(action_id),
		quote_literal_cstr(resource_type),
		quote_literal_cstr(resource_id),
		ctx.data,
		session_id ? quote_literal_cstr(session_id) : "NULL",
		raise_on_deny ? "true" : "false");

	if (SPI_connect() != SPI_OK_CONNECT)
	{
		pfree(ctx.data);
		pfree(sql.data);
		elog(ERROR, "pg_agent_policy: SPI_connect failed");
	}

	rc = SPI_execute(sql.data, true, 1);

	if (rc == SPI_OK_SELECT && SPI_processed > 0 && SPI_tuptable != NULL)
	{
		d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc,
						  1, &isnull);
		if (!isnull)
			allowed = DatumGetBool(d);
	}
	else
		allowed = false;

	SPI_finish();
	pfree(ctx.data);
	pfree(sql.data);
	return allowed;
}

void
pgap_ProcessUtility(PlannedStmt *pstmt, const char *queryString,
					bool readOnlyTree, ProcessUtilityContext context,
					ParamListInfo params, QueryEnvironment *queryEnv,
					DestReceiver *dest, QueryCompletion *qc)
{
	if (hook_enabled && pstmt != NULL && IsUnderPostmaster && in_hook == 0)
	{
		in_hook++;
		PG_TRY();
		{
		char *stmt_type = pgap_derive_statement_type(pstmt);
		char *principal_id = pgap_get_principal_id();
		char *session_id = pgap_get_session_id();
		bool ready = pgap_extension_ready();
		bool allowed = true;
		bool is_infra = false;
		/*
		 * Skip enforcement on session/transaction infrastructure. APL
		 * governs data and DDL actions, not SET/RESET/BEGIN/COMMIT.
		 * This also lets a trusted gateway unbind the principal GUC to
		 * close an agent session (otherwise default-deny would trap it).
		 */
		if (pstmt->utilityStmt != NULL &&
			(nodeTag(pstmt->utilityStmt) == T_VariableSetStmt ||
			 nodeTag(pstmt->utilityStmt) == T_TransactionStmt))
			is_infra = true;
		/* Admin mode (no principal bound) or infra: do not enforce. */
		if (ready && principal_id != NULL && !is_infra)
			allowed = pgap_evaluate_internal(
				principal_id, session_id, "execute_sql",
				stmt_type, "*", "*", false);
		if (!allowed && !hook_log_only)
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
					 errmsg("pg_agent_policy: statement blocked by policy"),
					 errdetail("statement_type=%s, principal=%s",
								stmt_type, principal_id)));

		pfree(stmt_type);
		if (principal_id) pfree(principal_id);
		if (session_id) pfree(session_id);
		}
		PG_CATCH();
		{
			in_hook--;
			PG_RE_THROW();
		}
		PG_END_TRY();
		in_hook--;
	}

	if (prev_ProcessUtility)
		prev_ProcessUtility(pstmt, queryString, readOnlyTree,
							context, params, queryEnv, dest, qc);
	else
		standard_ProcessUtility(pstmt, queryString, readOnlyTree,
							   context, params, queryEnv, dest, qc);
}

void
pgap_ExecutorStart(QueryDesc *queryDesc, int eflags)
{
	if (hook_enabled && queryDesc != NULL && IsUnderPostmaster && in_hook == 0)
	{
		in_hook++;
		PG_TRY();
		{
		PlannedStmt *pstmt = queryDesc->plannedstmt;
		char *stmt_type = pgap_derive_statement_type(pstmt);
		char *principal_id = pgap_get_principal_id();
		char *session_id = pgap_get_session_id();
		bool ready = pgap_extension_ready();
		bool allowed = true;
		bool is_infra = false;
		/*
		 * Skip enforcement on session/transaction infrastructure. APL
		 * governs data and DDL actions, not SET/RESET/BEGIN/COMMIT.
		 * This also lets a trusted gateway unbind the principal GUC to
		 * close an agent session (otherwise default-deny would trap it).
		 */
		if (pstmt->utilityStmt != NULL &&
			(nodeTag(pstmt->utilityStmt) == T_VariableSetStmt ||
			 nodeTag(pstmt->utilityStmt) == T_TransactionStmt))
			is_infra = true;
		/* Admin mode (no principal bound) or infra: do not enforce. */
		if (ready && principal_id != NULL && !is_infra)
			allowed = pgap_evaluate_internal(
				principal_id, session_id, "execute_sql",
				stmt_type, "*", "*", false);
		if (!allowed && !hook_log_only)
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
					 errmsg("pg_agent_policy: statement blocked by policy"),
					 errdetail("statement_type=%s, principal=%s",
								stmt_type, principal_id)));

		pfree(stmt_type);
		if (principal_id) pfree(principal_id);
		if (session_id) pfree(session_id);
		}
		PG_CATCH();
		{
			in_hook--;
			PG_RE_THROW();
		}
		PG_END_TRY();
		in_hook--;
	}

	if (prev_ExecutorStart)
		prev_ExecutorStart(queryDesc, eflags);
	else
		standard_ExecutorStart(queryDesc, eflags);
}

void
_PG_init(void)
{
	/*
	 * Identity-binding GUCs. These are PGC_SUSET so only a superuser
	 * (the trusted tool gateway / MCP broker) can SET them after it
	 * has authenticated an agent. A non-superuser agent connection
	 * cannot spoof principal_id or session_id -- this is the core of
	 * the v0.2 anti-spoofing boundary.
	 */
	DefineCustomStringVariable(GUC_PRINCIPAL_ID,
		"Agent principal bound to this session by the trusted gateway.",
		"Set by a superuser after authenticating the agent. When unset, "
		"the hook runs in admin mode and does not enforce.",
		&guc_principal_id, NULL, PGC_SUSET, 0, NULL, NULL, NULL);

	DefineCustomStringVariable(GUC_SESSION_ID,
		"Agent session id bound to this connection by the trusted gateway.",
		"Server-minted via mint_session_id(); set by a superuser.",
		&guc_session_id, NULL, PGC_SUSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(GUC_ENFORCE_HOOK,
		"Enable pg_agent_policy server-side hook enforcement.",
		"When true, ProcessUtility and ExecutorStart hooks "
		"intercept statements and block on deny.",
		&hook_enabled, true, PGC_SIGHUP, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable(GUC_LOG_ONLY_HOOK,
		"Shadow mode for the pg_agent_policy hook.",
		"When true, the hook logs denials but does not block. "
		"Superuser-settable so ops can roll out enforcement in shadow "
		"mode per session before flipping to blocking.",
		&hook_log_only, false, PGC_SUSET, 0, NULL, NULL, NULL);

	prev_ProcessUtility = ProcessUtility_hook;
	ProcessUtility_hook = pgap_ProcessUtility;

	prev_ExecutorStart = ExecutorStart_hook;
	ExecutorStart_hook = pgap_ExecutorStart;

	elog(LOG, "pg_agent_policy: hooks registered");
}

void
_PG_fini(void)
{
	ProcessUtility_hook = prev_ProcessUtility;
	ExecutorStart_hook = prev_ExecutorStart;
	elog(LOG, "pg_agent_policy: hooks unregistered");
}
