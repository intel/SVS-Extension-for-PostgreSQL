# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

MODULE_big = svs_capacity_search_test
OBJS = svs_capacity_search_test.o svs_capacity_search.o

EXTENSION = svs_capacity_search_test
DATA = svs_capacity_search_test--1.0.sql

REGRESS = svs_capacity_search_test

# svs_capacity_search.c has no dependency on the SVS vendor library, so it
# is compiled here directly from its real location rather than duplicated.
# A pattern-scoped vpath (not VPATH) so only .c lookups reach into src/;
# VPATH would also redirect the install step's search for our .control file.
vpath %.c ../../../src
PG_CPPFLAGS = -I../../../src

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
