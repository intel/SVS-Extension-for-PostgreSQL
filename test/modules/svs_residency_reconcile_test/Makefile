# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

MODULE_big = svs_residency_reconcile_test
OBJS = \
	svs_residency_reconcile_test.o \
	svs_index_residency.o \
	vamana_subxact_guard.o

EXTENSION = svs_residency_reconcile_test
DATA = svs_residency_reconcile_test--1.0.sql

# A pattern-scoped vpath (not VPATH) so only .c lookups reach into src/;
# VPATH would also redirect the install step's search for our .control file.
vpath %.c ../../../src

PG_CONFIG ?= pg_config
PG_CPPFLAGS = -I../../../src -I$(shell $(PG_CONFIG) --includedir-server)/extension/vector

TESTS = $(wildcard test/sql/*.sql)
REGRESS = $(patsubst test/sql/%.sql,%,$(TESTS))
REGRESS_OPTS = --inputdir=test

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
