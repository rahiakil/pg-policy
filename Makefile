EXTENSION = pg_agent_policy
DATA = sql/pg_agent_policy--0.1.0.sql sql/pg_agent_policy--0.2.0.sql sql/pg_agent_policy--0.1.0--0.2.0.sql
DOCS = doc/pg_agent_policy.md
REGRESS = basic security hook
REGRESS_OPTS = --inputdir=test

# v0.2 C module with ProcessUtility_hook + ExecutorStart_hook
# Built into pg_agent_policy.so, loaded via shared_preload_libraries
MODULE_big = pg_agent_policy
OBJS = src/pg_agent_policy.o

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
