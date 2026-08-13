# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

EXTENSION = svs
EXTVERSION = 0.1.0

MODULE_big = svs
DATA = sql/$(EXTENSION)--$(EXTVERSION).sql
OBJS = src/svs.o \
       src/vamana.o \
       src/vamana_replication.o \
       src/vamana_checkpoint.o \
       src/vamana_undo.o \
       src/vamanabuild.o \
       src/vamanacache.o \
       src/vamanaio.o \
       src/vamanainsert.o \
       src/vamanascan.o \
       src/vamanautils.o \
       src/vamanavacuum.o \
       src/vamanaworker.o \
       src/vamanaworkershmem.o \
       src/vamanaworkerindex.o \
       src/vamanaworkersearch.o \
       src/vamanaworkerwrite.o \
       src/svs_wrapper.o
HEADERS = src/vamana.h src/svs_wrapper.h

TESTS = $(wildcard test/sql/*.sql)
REGRESS = $(patsubst test/sql/%.sql,%,$(TESTS))
# Load pgvector first (for vector/halfvec types), then this extension
REGRESS_OPTS = --inputdir=test --load-extension=vector --load-extension=$(EXTENSION)

# To compile for portability, run: make OPTFLAGS=""
OPTFLAGS = -march=native

# Mac ARM doesn't always support -march=native
ifeq ($(shell uname -s), Darwin)
	ifeq ($(shell uname -p), arm)
		OPTFLAGS =
	endif
endif

# PowerPC doesn't support -march=native
ifneq ($(filter ppc64%, $(shell uname -m)), )
	OPTFLAGS =
endif

# RISC-V64 doesn't support -march=native
ifeq ($(shell uname -m), riscv64)
	OPTFLAGS =
endif

PG_CFLAGS += $(OPTFLAGS) -ftree-vectorize -fassociative-math -fno-signed-zeros -fno-trapping-math

# Coverage instrumentation, opt-in via 'make COVERAGE=1'. Kept out of default
# builds because --coverage slows the binary and writes .gcda files at runtime.
ifeq ($(COVERAGE),1)
PG_CFLAGS  += --coverage
SHLIB_LINK += --coverage
endif

# SVS library paths. Matches SVS_INSTALL_DIR in docs/build_guide/config; relative,
# so a bare 'make' works from the repository root after running the build guide.
SVS_INSTALL ?= docs/build_guide/svs_install

# Validate SVS library exists
ifeq (,$(wildcard $(SVS_INSTALL)/lib/libsvs_c_api.so))
$(error SVS library not found at $(SVS_INSTALL)/lib/libsvs_c_api.so. Run docs/build_guide/build_svs.sh first, or pass SVS_INSTALL=/path/to/svs_install)
endif

PG_CPPFLAGS += -DUSE_SVS -I$(SVS_INSTALL)/include -I$(shell $(PG_CONFIG) --includedir-server)/extension/vector
SHLIB_LINK += -L$(SVS_INSTALL)/lib -lsvs_c_api -Wl,-rpath,$(SVS_INSTALL)/lib

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)

# Remove GCC coverage artefacts on 'make clean'
EXTRA_CLEAN = $(wildcard src/*.gcda) $(wildcard src/*.gcno)

include $(PGXS)

# Expose the build's injection-point setting to TAP tests (fault-path tests
# skip themselves when it is not 'yes').
export enable_injection_points

# for Mac
ifeq ($(PROVE),)
	PROVE = prove
endif

# for Postgres < 15
PROVE_FLAGS += -I ./test/perl

prove_installcheck:
	rm -rf $(CURDIR)/tmp_check
	cd $(srcdir) && TESTDIR='$(CURDIR)' PATH="$(bindir):$$PATH" LD_LIBRARY_PATH="$(shell $(PG_CONFIG) --libdir):$$LD_LIBRARY_PATH" PGPORT='6$(DEF_PGPORT)' PG_REGRESS='$(top_builddir)/src/test/regress/pg_regress' $(PROVE) $(PG_PROVE_FLAGS) $(PROVE_FLAGS) $(if $(PROVE_TESTS),$(PROVE_TESTS),test/t/*.pl)

# ---------------------------------------------------------------------------
# Coverage report targets
#
# Workflow:
#   1. make COVERAGE=1                          (builds with instrumentation)
#   2. make install && make prove_installcheck  (accumulates .gcda counters)
#   3. make coverage                            (generates all three report formats)
#
# To start a clean measurement run:
#   make coverage-clean && make prove_installcheck && make coverage
# ---------------------------------------------------------------------------

GCOVR      ?= gcovr
COVERAGE_FILTER = --filter src/

# coverage: generate text summary, AI-consumable JSON, and interactive HTML
coverage:
	mkdir -p coverage_reports
	$(GCOVR) $(COVERAGE_FILTER) --txt coverage_reports/coverage.txt
	$(GCOVR) $(COVERAGE_FILTER) --json-pretty --output coverage_reports/coverage.json
	$(GCOVR) $(COVERAGE_FILTER) --html-details coverage_reports/index.html
	@echo "Coverage reports written to coverage_reports/"

# coverage-clean: zero .gcda counters so the next test run starts fresh.
# Does NOT remove .gcno files (those require a recompile to regenerate).
coverage-clean:
	find $(CURDIR)/src -name '*.gcda' -delete
	@echo "Coverage counters reset (*.gcda removed)"

.PHONY: coverage coverage-clean
