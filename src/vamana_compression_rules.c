/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamana_compression_rules.c
 *
 * The compression_type/compression_primary/compression_secondary validity
 * rules, in one place with no dependencies beyond libc. CREATE INDEX's
 * reloption validation (vamanabuild.c) and the metapage reader's
 * corruption check (vamanautils.c) both decide validity through
 * VamanaCompressionConfigIsValid, so there is one set of rules rather than
 * two that could drift apart. Having no dependencies also lets a
 * standalone test module link this file directly.
 */

#include "postgres.h"

#include "vamana.h"

/* Valid quantization encodings for compression_primary/compression_secondary. */
static const int VAMANA_VALID_COMPRESSION_VALUES[] = {
	VAMANA_LEANVEC_UINT4,
	VAMANA_LEANVEC_INT4,
	VAMANA_LEANVEC_UINT8,
	VAMANA_LEANVEC_INT8
};
#define VAMANA_NUM_COMPRESSION_VALUES \
	(sizeof(VAMANA_VALID_COMPRESSION_VALUES) / sizeof(VAMANA_VALID_COMPRESSION_VALUES[0]))

/*
 * (primary bits, residual bits) pairs SVS compiles LVQ specializations for.
 * A pair outside this set fails deep inside the library when the loader
 * looks for a matching specialization, so it is rejected here instead.
 * Widen this table if an SVS build ever adds specializations; the rule
 * itself does not need rewriting.
 */
typedef struct VamanaLVQPair
{
	int			primary_bits;
	int			residual_bits;
}			VamanaLVQPair;

static const VamanaLVQPair VAMANA_VALID_LVQ_PAIRS[] = {
	{4, 0},
	{8, 0},
	{4, 4},
	{4, 8}
};
#define VAMANA_NUM_LVQ_PAIRS \
	(sizeof(VAMANA_VALID_LVQ_PAIRS) / sizeof(VAMANA_VALID_LVQ_PAIRS[0]))

/*
 * Whether value is one of the quantization encodings in
 * VAMANA_VALID_COMPRESSION_VALUES, independent of allow_none handling.
 */
bool
CompressionValueInSet(int value)
{
	for (size_t i = 0; i < VAMANA_NUM_COMPRESSION_VALUES; i++)
	{
		if (value == VAMANA_VALID_COMPRESSION_VALUES[i])
			return true;
	}

	return false;
}

static bool
VamanaLVQPairIsValid(int primary_bits, int secondary_bits)
{
	for (size_t i = 0; i < VAMANA_NUM_LVQ_PAIRS; i++)
	{
		if (primary_bits == VAMANA_VALID_LVQ_PAIRS[i].primary_bits &&
			secondary_bits == VAMANA_VALID_LVQ_PAIRS[i].residual_bits)
			return true;
	}

	return false;
}

bool
VamanaCompressionConfigIsValid(int compression_type, int compression_primary,
							   int compression_secondary)
{
	int			primary_bits = abs(compression_primary);
	int			secondary_bits = abs(compression_secondary);

	if (compression_type == VAMANA_COMPRESSION_NONE)
		return true;

	if (compression_type == VAMANA_COMPRESSION_LEANVEC)
	{
		if (!CompressionValueInSet(compression_primary) ||
			!CompressionValueInSet(compression_secondary))
			return false;

		return primary_bits <= secondary_bits;
	}

	if (compression_type == VAMANA_COMPRESSION_LVQ)
	{
		bool		secondary_ok;

		if (!CompressionValueInSet(compression_primary))
			return false;

		secondary_ok = (compression_secondary == VAMANA_COMPRESSION_NO_RESIDUAL) ||
			CompressionValueInSet(compression_secondary);
		if (!secondary_ok)
			return false;

		return VamanaLVQPairIsValid(primary_bits, secondary_bits);
	}

	return false;
}
