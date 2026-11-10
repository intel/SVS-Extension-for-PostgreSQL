# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

MODULE_big = svs_unsupported_hw_test
OBJS = svs_unsupported_hw_test.o svs_wrapper.o

EXTENSION = svs_unsupported_hw_test
DATA = svs_unsupported_hw_test--1.0.sql

# A pattern-scoped vpath (not VPATH) so only .c lookups reach into src/;
# VPATH would also redirect the install step's search for our .control file.
vpath %.c ../../../src

PG_CONFIG = pg_config

# svs_wrapper.c calls real SVS library functions elsewhere in the file (not in
# the one function this module drives), so its symbols must still resolve;
# mirror the main extension Makefile's SVS_INSTALL wiring, not
# svs_meta_counts_test's SVS-free one.
SVS_INSTALL ?= svs_install_public
override SVS_INSTALL := $(abspath $(SVS_INSTALL))

ifeq (,$(wildcard $(SVS_INSTALL)/lib/libsvs_c_api.so))
$(error SVS library not found at $(SVS_INSTALL)/lib/libsvs_c_api.so. Set SVS_INSTALL correctly)
endif

PG_CPPFLAGS = -I../../../src -isystem $(SVS_INSTALL)/include -I$(shell $(PG_CONFIG) --includedir-server)/extension/vector
SHLIB_LINK = -L$(SVS_INSTALL)/lib -lsvs_c_api -Wl,-rpath,$(SVS_INSTALL)/lib

TESTS = $(wildcard test/sql/*.sql)
REGRESS = $(patsubst test/sql/%.sql,%,$(TESTS))
REGRESS_OPTS = --inputdir=test

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
