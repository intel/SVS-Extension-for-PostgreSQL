# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

MODULE_big = svs_umask_test
OBJS = svs_umask_test.o

EXTENSION = svs_umask_test
DATA = svs_umask_test--1.0.sql

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
