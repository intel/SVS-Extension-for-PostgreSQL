# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

MODULE_big = svs_cpu_budget_test
OBJS = \
	svs_cpu_budget_test.o \
	svs_cpu_budget.o

EXTENSION = svs_cpu_budget_test
DATA = svs_cpu_budget_test--1.0.sql

REGRESS = svs_cpu_budget_test

PG_CPPFLAGS = -I../../../src
vpath %.c ../../../src

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
