/*
 * pg_agent_policy.h - v0.2 hook declarations
 *
 * pg_agent_policy is a PostgreSQL-resident Plane-B policy layer for
 * database-facing agent tools. v0.1 shipped a SQL-callable evaluate()
 * PDP/PEP beside RLS. v0.2 adds the C-level hooks that make skipping
 * evaluate() impossible: ProcessUtility_hook for DDL/utility and
 * ExecutorStart_hook for statement-class checks.
 *
 * The hook derives security-critical facts (statement_type, command tag)
 * from the parsed SQL AST and OVERRIDES caller-supplied context for those
 * fields. Identity is bound to current_user / a login GUC set by a
 * trusted PEP. Temporal checks use ATOMIC_CHECK_THEN_RECORD so the
 * budget cannot be violated under concurrency.
 *
 * License: PostgreSQL License
 */
#ifndef PG_AGENT_POLICY_H
#define PG_AGENT_POLICY_H

#include "postgres.h"

/*
 * GUC names. A trusted PEP sets these at login (or per-transaction)
 * via SET. The hook reads them and overrides any caller-supplied
 * principal/session context. If a GUC is unset, the hook falls
 * back to current_user for principal_id and refuses to mint a session
 * id from caller input.
 */
#define GUC_PRINCIPAL_ID   "pg_agent_policy.principal_id"
#define GUC_SESSION_ID     "pg_agent_policy.session_id"
#define GUC_ENFORCE_HOOK   "pg_agent_policy.hook_enabled"
#define GUC_LOG_ONLY_HOOK  "pg_agent_policy.hook_log_only"

/*
 * statement_class values derived from the AST, never from caller JSON.
 * These are the tags the hook overrides into context.statement_type.
 */
#define ST_SELECT    "SELECT"
#define ST_INSERT    "INSERT"
#define ST_UPDATE     "UPDATE"
#define ST_DELETE     "DELETE"
#define ST_MERGE      "MERGE"
#define ST_CREATE     "CREATE"
#define ST_DROP       "DROP"
#define ST_ALTER      "ALTER"
#define ST_TRUNCATE   "TRUNCATE"
#define ST_GRANT      "GRANT"
#define ST_REVOKE     "REVOKE"
#define ST_COPY       "COPY"
#define ST_OTHER      "OTHER"

/* Hook function declarations (defined in pg_agent_policy.c) */
void pgap_init_hook(void);
void pgap_ProcessUtility(PlannedStmt *pstmt, const char *queryString,
                          bool readOnlyTree, ProcessUtilityContext context,
                          ParamListInfo params, QueryEnvironment *queryEnv,
                          DestReceiver *dest, QueryCompletion *qc);
void pgap_ExecutorStart(QueryDesc *queryDesc, int eflags);

/* Helpers exposed for testing / SPI */
extern char *pgap_derive_statement_type(PlannedStmt *pstmt);
extern char *pgap_get_principal_id(void);
extern char *pgap_get_session_id(void);
extern bool pgap_evaluate_internal(const char *principal_id,
                                    const char *session_id,
                                    const char *action_id,
                                    const char *statement_type,
                                    const char *resource_type,
                                    const char *resource_id,
                                    bool raise_on_deny);

#endif /* PG_AGENT_POLICY_H */
