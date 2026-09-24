# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

MODULE_big = svs_vector_buffer_test
OBJS = \
	svs_vector_buffer_test.o \
	svs_vector_buffer.o

EXTENSION = svs_vector_buffer_test
DATA = svs_vector_buffer_test--1.0.sql

REGRESS = svs_vector_buffer_test

EXTRA_CLEAN = $(wildcard *.gcda) $(wildcard *.gcno)

PG_CPPFLAGS = -I../../../src
vpath %.c ../../../src

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
