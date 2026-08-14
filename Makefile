EXTENSION = pg_agent_policy
DATA = sql/pg_agent_policy--0.1.0.sql
DOCS = doc/pg_agent_policy.md
REGRESS = basic
REGRESS_OPTS = --inputdir=test

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
