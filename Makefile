EXTENSION = pg_policy
DATA = sql/pg_policy--0.1.0.sql
DOCS = doc/pg_policy.md
REGRESS = basic
REGRESS_OPTS = --inputdir=test

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
