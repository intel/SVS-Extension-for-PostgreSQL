# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

MODULE_big = svs_memory_test
OBJS = \
	svs_memory_test.o \
	svs_memory_test_fakeshmem.o \
	svs_memory.o

EXTENSION = svs_memory_test
DATA = svs_memory_test--1.0.sql

REGRESS = svs_memory_test

PG_CPPFLAGS = -I../../../src
vpath %.c ../../../src

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
