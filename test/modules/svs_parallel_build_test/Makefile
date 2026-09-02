# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

MODULE_big = svs_parallel_build_test
OBJS = svs_parallel_build_test.o svs_parallel_build.o svs_slot_naming.o

EXTENSION = svs_parallel_build_test
DATA = svs_parallel_build_test--1.0.sql

# svs_parallel_build.c (and its own svs_slot_naming.c dependency) have no
# dependency on the SVS vendor library, so they are compiled here directly
# from their real location rather than duplicated.
# A pattern-scoped vpath (not VPATH) so only .c lookups reach into src/;
# VPATH would also redirect the install step's search for our .control file.
vpath %.c ../../../src
PG_CPPFLAGS = -I../../../src

TESTS = $(wildcard test/sql/*.sql)
REGRESS = $(patsubst test/sql/%.sql,%,$(TESTS))
REGRESS_OPTS = --inputdir=test

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
