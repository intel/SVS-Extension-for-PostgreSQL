# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

MODULE_big = svs_cache_kick_test
OBJS = svs_cache_kick_test.o vamanacache.o

EXTENSION = svs_cache_kick_test
DATA = svs_cache_kick_test--1.0.sql

# vamanacache.c has no dependency on the SVS vendor library or on the rest
# of the extension's shared-memory/replication machinery for the eviction
# arithmetic this module exercises; the handful of cross-file calls it does
# make are stubbed in svs_cache_kick_test.c. Compiled here directly from its
# real location rather than duplicated, the same pattern svs_cpu_slots_test
# uses for svs_cpu_slots.c.
# A pattern-scoped vpath (not VPATH) so only .c lookups reach into src/;
# VPATH would also redirect the install step's search for our .control file.
vpath %.c ../../../src
PG_CONFIG_FOR_INCLUDES = pg_config
PG_CPPFLAGS = -I../../../src -I$(shell $(PG_CONFIG_FOR_INCLUDES) --includedir-server)/extension/vector

TESTS = $(wildcard test/sql/*.sql)
REGRESS = $(patsubst test/sql/%.sql,%,$(TESTS))
REGRESS_OPTS = --inputdir=test

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
