# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

MODULE_big = svs_multi_insert_bounds_test
OBJS = svs_multi_insert_bounds_test.o vamana_replication.o

EXTENSION = svs_multi_insert_bounds_test
DATA = svs_multi_insert_bounds_test--1.0.sql

vpath %.c ../../../src

PG_CONFIG = pg_config
PG_CPPFLAGS = -I../../../src -I$(shell $(PG_CONFIG) --includedir-server)/extension/vector

TESTS = $(wildcard test/sql/*.sql)
REGRESS = $(patsubst test/sql/%.sql,%,$(TESTS))
REGRESS_OPTS = --inputdir=test

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
