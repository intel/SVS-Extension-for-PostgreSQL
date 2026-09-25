/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamanabuild.c
 *
 * Index build implementation for Vamana index using SVS library.
 * Uses simplified batch approach where SVS handles parallelism internally.
 */

#include "postgres.h"

#include <math.h>

#include "vamana.h"
#include "svs_build_thread_grant.h"
#include "svs_index_residency.h"
#include "svs_memory.h"
#include "svs_wrapper.h"
#include "vamana_replication.h"
#include "vamanaworker.h"

#include "access/amapi.h"
#include "access/heapam.h"
#include "access/relscan.h"
#include "access/table.h"
#include "access/tableam.h"
#include "access/xlog.h"
#include "access/xloginsert.h"
#include "catalog/index.h"
#include "commands/progress.h"
#include "common/int.h"
#include "miscadmin.h"
#include "pgstat.h"
#include "storage/bufmgr.h"
#include "storage/ipc.h"
#include "storage/lmgr.h"
#include "tcop/tcopprot.h"
#include "utils/injection_point.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

#if PG_VERSION_NUM >= 140000
#include "utils/backend_progress.h"
#else
#include "pgstat.h"
#endif

/*
 * Callback for table_index_build_scan - accumulates vectors in buffer
 */
static void
BuildCallback(Relation index, ItemPointer tid, Datum *values,
			  bool *isnull, bool tupleIsAlive, void *state)
{
	VamanaBuildState *buildstate = (VamanaBuildState *) state;
	float	   *floats;
	int			dimensions;

	if (isnull[0])
		return;

	floats = VamanaDatumToFloats(buildstate->typeInfo, values[0],
								 &dimensions, "build");

	SvsVectorBufferAppend(&buildstate->vectors, floats);
	pfree(floats);

	if (buildstate->tidBufferCapacity < buildstate->vectors.capacity)
	{
		buildstate->tidBufferCapacity = buildstate->vectors.capacity;
		buildstate->tidBuffer = repalloc_huge(buildstate->tidBuffer,
										 buildstate->tidBufferCapacity * sizeof(ItemPointerData));
	}
	ItemPointerCopy(tid, &buildstate->tidBuffer[buildstate->vectors.count - 1]);
}

/*
 * Create the metapage
 */
static void
CreateMetaPage(VamanaBuildState * buildstate)
{
	Relation	index = buildstate->index;
	ForkNumber	forkNum = buildstate->forkNum;
	Buffer		buf;
	Page		page;
	VamanaMetaPage metap;

	buf = VamanaNewBuffer(index, forkNum);
	page = BufferGetPage(buf);
	VamanaInitPage(buf, page);

	metap = VamanaPageGetMeta(page);
	metap->magicNumber = VAMANA_MAGIC_NUMBER;
	metap->dimensions = buildstate->dimensions;
	metap->graph_degree = buildstate->graph_degree;
	metap->alpha = buildstate->alpha;
	metap->compression_type = buildstate->compression_type;
	metap->compression_primary = buildstate->compression_primary;
	metap->compression_secondary = buildstate->compression_secondary;
	metap->indexDataBlkno = InvalidBlockNumber;
	metap->indexDataSize = 0;
	metap->numVectors = 0;
	metap->hasSavedIndex = false;
	metap->nextExternalId = 0;
	metap->numDeleted = 0;
	metap->tidMappingCapacity = 0;

	((PageHeader) page)->pd_lower =
		((char *) metap + sizeof(VamanaMetaPageData)) - (char *) page;

	MarkBufferDirty(buf);
	UnlockReleaseBuffer(buf);
}

/*
 * Serialize the SVS index to disk and update the metapage.
 */
static void
SerializeIndexToPages(VamanaBuildState * buildstate, SVSIndexHandle svsIndex)
{
	VamanaIndexCache meta;

	memset(&meta, 0, sizeof(meta));
	meta.indexRelid = RelationGetRelid(buildstate->index);
	meta.svsIndex = svsIndex;
	meta.isValid = true;
	meta.dimensions = buildstate->dimensions;
	meta.graph_degree = buildstate->graph_degree;
	meta.alpha = VAMANA_ALPHA_TO_FLOAT(buildstate->alpha);
	meta.tidMapping = buildstate->tidBuffer;
	meta.numVectors = (int) buildstate->vectors.count;
	meta.tidMappingCapacity = (int) buildstate->vectors.count;
	meta.nextExternalId = (uint64) buildstate->vectors.count;
	meta.numDeleted = 0;
	meta.needsSave = false;

	VamanaSaveIndexToDisk(buildstate->index, svsIndex, buildstate->forkNum, &meta);
}

/* Valid compression values; used only in this file */
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
 * A pair outside this set fails deep inside the library when the loader looks
 * for a matching specialization, so it is rejected here instead.  Widen this
 * table if an SVS build ever adds specializations; the rule itself does not
 * need rewriting.
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
 * Validate compression parameter (must be one of the valid values).  allow_none
 * additionally accepts 0; pass it only for LVQ's residual, the one parameter
 * for which "absent" is a legal value.
 */
static void
ValidateCompressionParam(int value, const char *param_name, bool allow_none)
{
	bool		is_valid = false;

	if (allow_none && value == VAMANA_COMPRESSION_NO_RESIDUAL)
		return;

	for (size_t i = 0; i < VAMANA_NUM_COMPRESSION_VALUES; i++)
	{
		if (value == VAMANA_VALID_COMPRESSION_VALUES[i])
		{
			is_valid = true;
			break;
		}
	}

	if (!is_valid)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("invalid %s value: %d", param_name, value),
				 errhint("Valid values are: %d (UINT4), %d (INT4), %d (UINT8), %d (INT8)%s",
						 VAMANA_LEANVEC_UINT4, VAMANA_LEANVEC_INT4,
						 VAMANA_LEANVEC_UINT8, VAMANA_LEANVEC_INT8,
						 allow_none ? ", 0 (no residual)" : "")));
	}
}

/*
 * Validate the compression reloptions as a set.  Parameters belonging to a
 * scheme other than the one selected are ignored rather than rejected, which
 * is how the other irrelevant-parameter cases behave (leanvec_dims under LVQ,
 * every compression parameter under compression_type = none).
 */
static void
ValidateCompressionOptions(int compression_type, int compression_primary,
						   int compression_secondary)
{
	int			primary_bits = abs(compression_primary);
	int			secondary_bits = abs(compression_secondary);

	if (compression_type == VAMANA_COMPRESSION_LEANVEC)
	{
		ValidateCompressionParam(compression_primary, "compression_primary", false);
		ValidateCompressionParam(compression_secondary, "compression_secondary", false);

		if (primary_bits > secondary_bits)
		{
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("compression_primary (%d-bit) cannot have higher precision than compression_secondary (%d-bit)",
							primary_bits, secondary_bits),
					 errhint("Primary quantization must be <= secondary precision (e.g., 4-bit primary with 8-bit secondary is valid)")));
		}
	}
	else if (compression_type == VAMANA_COMPRESSION_LVQ)
	{
		bool		is_valid = false;

		ValidateCompressionParam(compression_primary, "compression_primary", false);
		ValidateCompressionParam(compression_secondary, "compression_secondary", true);

		for (size_t i = 0; i < VAMANA_NUM_LVQ_PAIRS; i++)
		{
			if (primary_bits == VAMANA_VALID_LVQ_PAIRS[i].primary_bits &&
				secondary_bits == VAMANA_VALID_LVQ_PAIRS[i].residual_bits)
			{
				is_valid = true;
				break;
			}
		}

		if (!is_valid)
		{
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("unsupported LVQ configuration: %d-bit primary with %d-bit residual",
							primary_bits, secondary_bits),
					 errhint("Supported LVQ configurations are 4- or 8-bit primary with no residual (compression_secondary = 0), or 4-bit primary with a 4- or 8-bit residual.")));
		}
	}
}

/*
 * Initialize build state
 */
static void
InitBuildState(VamanaBuildState * buildstate, Relation heap, Relation index,
			   IndexInfo *indexInfo, ForkNumber forkNum)
{
	VamanaOptions *opts = (VamanaOptions *) index->rd_options;

	buildstate->heap = heap;
	buildstate->index = index;
	buildstate->indexInfo = indexInfo;
	buildstate->forkNum = forkNum;
	buildstate->typeInfo = VamanaGetTypeInfo(index);

	buildstate->graph_degree = opts ? opts->graph_degree : VAMANA_DEFAULT_GRAPH_DEGREE;
	/* If alpha = -1, SVS uses its internal default (1.2 for L2) */
	buildstate->alpha = opts ? opts->alpha : VAMANA_DEFAULT_ALPHA;
	buildstate->build_window_size = opts ? opts->build_window_size : VAMANA_DEFAULT_BUILD_WINDOW;
	buildstate->search_window_size = VamanaResolveSearchWindowSize(opts);
	buildstate->use_search_history = opts ? opts->use_search_history : VAMANA_DEFAULT_USE_SEARCH_HISTORY;

	buildstate->compression_type = opts ? opts->compression_type : VAMANA_DEFAULT_COMPRESSION_TYPE;

	buildstate->compression_primary = opts ? opts->compression_primary : VAMANA_DEFAULT_COMPRESSION_PRIMARY;
	buildstate->compression_secondary = opts ? opts->compression_secondary : VAMANA_DEFAULT_COMPRESSION_SECONDARY;
	buildstate->leanvec_dims = opts ? opts->leanvec_dims : VAMANA_DEFAULT_LEANVEC_DIMS;

	ValidateCompressionOptions(buildstate->compression_type,
							   buildstate->compression_primary,
							   buildstate->compression_secondary);

	buildstate->dimensions = TupleDescAttr(index->rd_att, 0)->atttypmod;

	/* Validate dimensions */
	if (buildstate->dimensions < 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("column does not have dimensions")));

	if (buildstate->dimensions > VAMANA_MAX_DIM)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("column cannot have more than %d dimensions for vamana index", VAMANA_MAX_DIM)));

	buildstate->reltuples = 0;
	buildstate->indtuples = 0;

	VamanaInitSupport(&buildstate->support, index);

	buildstate->distance_type = VamanaGetDistanceMetric(index);

	buildstate->buildCtx = AllocSetContextCreate(CurrentMemoryContext,
												 "Vamana build context",
												 ALLOCSET_DEFAULT_SIZES);
	buildstate->tmpCtx = AllocSetContextCreate(CurrentMemoryContext,
											   "Vamana build temporary context",
											   ALLOCSET_DEFAULT_SIZES);
}

/*
 * Free build state resources
 */
static void
FreeBuildState(VamanaBuildState * buildstate)
{
	SvsVectorBufferFree(&buildstate->vectors);
	pfree(buildstate->tidBuffer);

	MemoryContextDelete(buildstate->buildCtx);
	MemoryContextDelete(buildstate->tmpCtx);
}

/*
 * Closure for SvsRunGovernedBuild: the actual SVS graph build, run once the
 * thread count is known.  ids is generated here, not passed in, since its
 * only use is this call and its size depends on numVectors either way.
 */
typedef struct VamanaSVSBuildContext
{
	SVSBuilderHandle builder;
	const float *flatData;
	int			numVectors;
	int			graph_degree;
	int			dimensions;

	SVSIndexHandle result;
	int			errorCode;
} VamanaSVSBuildContext;

static void
VamanaRunSVSBuild(int grantedThreads, void *context)
{
	VamanaSVSBuildContext *ctx = (VamanaSVSBuildContext *) context;
	size_t	   *ids = MemoryContextAllocHuge(CurrentMemoryContext, (size_t) ctx->numVectors * sizeof(size_t));

	for (int i = 0; i < ctx->numVectors; i++)
		ids[i] = (size_t) i;

	SVSBuilderSetThreadpool(ctx->builder, grantedThreads);
	ctx->result = SVSBuildDynamicIndex(ctx->builder, ctx->flatData, ids,
										ctx->numVectors, ctx->graph_degree,
										ctx->dimensions, &ctx->errorCode);
	pfree(ids);
}

/*
 * Index-shape parameters needed to construct an SVS algorithm/storage/
 * builder triple.  Deliberately narrower than VamanaBuildState: the only
 * callers building fresh (vamanabuild, VamanaRebuildFromTable) source these
 * from different places (reloptions vs. a live scan), and this keeps the
 * builder lifecycle below decoupled from either caller's own state.  relid
 * is identity rather than shape, but both callers have it on hand and an
 * admission check needs it to size an estimate against the right index.
 */
typedef struct VamanaSVSIndexParams
{
	Oid				relid;
	int				dimensions;
	int				graph_degree;
	int				alpha;
	int				build_window_size;
	int				search_window_size;
	bool			use_search_history;
	int				compression_type;
	int				compression_primary;
	int				compression_secondary;
	int				leanvec_dims;
	SVSDistanceType	distance_type;
	SVSDType		data_type;
} VamanaSVSIndexParams;

/*
 * The build-peak margin is a calibrated 15%. buildPeak/6 is ~16.7%, the
 * smallest integer divisor whose margin does not fall below 15% (7 would
 * give only ~14.3%, undershooting the calibrated figure).
 */
#define VAMANA_BUILD_MEMORY_MARGIN_DIVISOR 6

/*
 * Per-backend baseline: PostgreSQL/SVS/MKL startup and session overhead,
 * the only fixed-cost term in the build-peak estimate. Scales with vector
 * dimensionality, not compression_type. From a 54-configuration
 * calibration sweep, measured at exactly the three dimensions below; see
 * SvsDimBaselineBytes for how an unmeasured dimension is charged.
 */
static const struct { int dims; double baseline_mb; } SvsDimBaselineTable[] = {
	{ 128,  50.97 },
	{ 768,  107.89 },
	{ 1536, 132.50 },
};

/*
 * Dimension-dependent adjustment to rawBuffer, shared by every
 * compression_type. Positive at 128 (128*4 bytes lands exactly on an
 * allocator size class, the tightest margin measured); the fitted values
 * at 768/1536 are negative (this host's overcommit behavior, not a
 * general property) and clamped to zero so they can only add margin, never
 * remove it. Same source as SvsDimBaselineTable above.
 */
static const struct { int dims; double raw_multiplier; } SvsDimAdjustmentTable[] = {
	{ 128,  0.80 },
	{ 768,  0.0 },			/* fitted -0.226, clamped to zero */
	{ 1536, 0.0 },			/* fitted -0.289, clamped to zero */
};

/*
 * LeanVec's extra full-precision working copy of the input, needed to
 * derive its reduced-dimension representation, as a multiple of
 * rawBuffer. Applied only when compression_type is
 * VAMANA_COMPRESSION_LEANVEC. The dim=128 value is the least trusted:
 * LeanVec's footprint there ignores leanvec_dims and compression_primary
 * in this SVS build, so it reflects a fixed library fallback, not a
 * tuned trade-off. Same source as SvsDimBaselineTable above.
 */
static const struct { int dims; double raw_multiplier; } SvsLeanVecExtraTable[] = {
	{ 128,  0.77 },
	{ 768,  1.26 },
	{ 1536, 1.29 },
};

/*
 * Only 128, 768 and 1536 dimensions were measured, and interpolation across
 * three points is not supported by the data: a linear fit of the baseline
 * table misses the measured 768 point by 12%, because the true progression
 * decelerates and three points cannot distinguish a curve from noise. So an
 * unmeasured dimension is charged the maximum value in the table rather than
 * the nearest neighbour or an interpolated one, on every one of these three
 * tables independently. That upper envelope is the only rule available from
 * three points that cannot under-predict at a dimension none of them
 * measured; it is conservative by construction, not by tuning, and it
 * should be replaced by real measurements at additional dimensions rather
 * than by a fitted curve.
 */
static double
SvsDimBaselineBytes(int dimensions)
{
	double		maxMb = 0;

	for (int i = 0; i < lengthof(SvsDimBaselineTable); i++)
	{
		if (SvsDimBaselineTable[i].dims == dimensions)
			return SvsDimBaselineTable[i].baseline_mb * 1024 * 1024;
		maxMb = Max(maxMb, SvsDimBaselineTable[i].baseline_mb);
	}
	return maxMb * 1024 * 1024;
}

static double
SvsDimAdjustmentMultiplier(int dimensions)
{
	double		maxMultiplier = 0;

	for (int i = 0; i < lengthof(SvsDimAdjustmentTable); i++)
	{
		if (SvsDimAdjustmentTable[i].dims == dimensions)
			return SvsDimAdjustmentTable[i].raw_multiplier;
		maxMultiplier = Max(maxMultiplier, SvsDimAdjustmentTable[i].raw_multiplier);
	}
	return maxMultiplier;
}

static double
SvsLeanVecExtraMultiplier(int dimensions)
{
	double		maxMultiplier = 0;

	for (int i = 0; i < lengthof(SvsLeanVecExtraTable); i++)
	{
		if (SvsLeanVecExtraTable[i].dims == dimensions)
			return SvsLeanVecExtraTable[i].raw_multiplier;
		maxMultiplier = Max(maxMultiplier, SvsLeanVecExtraTable[i].raw_multiplier);
	}
	return maxMultiplier;
}

/*
 * Adds a and b, raising an admission-time error naming relid rather than
 * silently wrapping, since every term downstream of this sum multiplies
 * numVectors by dimensions and a wrapped sum would under-predict the one
 * number this gate exists to get right.
 */
static uint64
SvsBuildPeakCheckedAdd(uint64 a, uint64 b, Oid relid)
{
	uint64		result;

	if (pg_add_u64_overflow(a, b, &result))
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("build memory estimate for index %u overflowed", relid)));
	return result;
}

/*
 * Builds an SVS index under a launcher-granted thread count, from an
 * already-flattened vector array the caller retains ownership of.  Owns the
 * builder/storage/algorithm handles it creates and frees all of them on
 * every exit path, including an ERROR raised while waiting for or running
 * under the grant -- the SVS handles are native objects that PostgreSQL's
 * own memory-context cleanup does not know how to reclaim.
 *
 * Writes the admission gate's buildPeak through *buildPeakOut as soon as it
 * is computed, regardless of how the build itself later turns out: the
 * caller needs the identical value to confirm the reservation, and
 * recomputing it independently would risk a one-byte mismatch that leaves a
 * silent phantom in the committed counter (the release is floored).
 */
static SVSIndexHandle
VamanaBuildSVSIndexGoverned(const VamanaSVSIndexParams *params,
							 const float *flatData, int numVectors,
							 int64 bufferCapacity,
							 int *errorCodeOut, uint64 *buildPeakOut)
{
	SVSAlgorithmHandle algorithm;
	SVSStorageHandle storage;
	SVSBuilderHandle builder;
	VamanaSVSBuildContext buildCtx;
	Size		dataSize;
	int			buildWindow = params->build_window_size > 0 ?
		params->build_window_size : VAMANA_BUILD_WINDOW_FROM_DEGREE(params->graph_degree);

	algorithm = SVSCreateAlgorithm(params->graph_degree, buildWindow,
									params->search_window_size, params->alpha,
									params->use_search_history);

	storage = SVSCreateStorageForCompression(params->compression_type,
											 params->data_type,
											 params->dimensions,
											 params->leanvec_dims,
											 params->compression_primary,
											 params->compression_secondary);

	builder = SVSCreateBuilder(params->distance_type, params->dimensions, algorithm);
	SVSBuilderSetStorage(builder, storage);

	PG_TRY();
	{
		/*
		 * The admission gate belongs here: the builder above exists for it
		 * to estimate against, and nothing below it has allocated yet.
		 */
		INJECTION_POINT("vamana-build-governed-pre-allocation", NULL);

		/*
		 * Unreachable in practice: dimensions is capped at VAMANA_MAX_DIM
		 * (2000) by both callers, so firing needs more than ~2.3e15 vectors
		 * on a 64-bit system.  Guards the multiplication as belt-and-braces.
		 */
		if (bufferCapacity > 0 &&
			(size_t) params->dimensions > SIZE_MAX / sizeof(float) / (size_t) bufferCapacity)
			ereport(ERROR,
					(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
					 errmsg("vector dataset too large to index "
							"(%d vectors x %d dimensions exceeds memory limit)",
							numVectors, params->dimensions)));

		/*
		 * Priced against the buffer's allocated capacity rather than
		 * numVectors: SvsVectorBuffer doubles on growth, so the buffer live
		 * during the build can hold up to ~2x more than the final count.
		 */
		dataSize = (Size) bufferCapacity * params->dimensions * sizeof(float);

		/*
		 * Memory admission gate. Estimates this build's peak backend RSS
		 * and reserves it against svs.max_build_memory and this database's
		 * residency budget before SvsRunGovernedBuild below runs;
		 * SvsMemoryReserveBuild raises its own ERROR, naming the GUC, on
		 * rejection. This runs ahead of the CPU-side pending-build
		 * admission inside SvsRunGovernedBuild further down, so a build
		 * refused here never consumes a launcher grant slot; the accepted
		 * cost of that order is that buildPeak stays committed while this
		 * backend waits for the grant, bounded by vamana_worker_timeout_ms.
		 */
		{
			SVSMemoryBreakdown breakdown;
			uint64		rawBuffer = (uint64) dataSize;
			uint64		residency;
			uint64		buildPeak;
			uint64		term;

			SVSEstimateBuildMemory(builder, numVectors, &breakdown);

			/*
			 * The three components cross a C ABI from the SVS library. A
			 * wrapped or zeroed estimate would silently pass a gate whose
			 * only purpose is refusing an oversized build, so validate
			 * before doing arithmetic on it: reject overflow on the sum,
			 * and reject an implausible all-zero estimate for a non-empty
			 * build.
			 */
			residency = SvsBuildPeakCheckedAdd(breakdown.graphBytes,
												breakdown.dataBytes,
												params->relid);
			residency = SvsBuildPeakCheckedAdd(residency,
												breakdown.metadataBytes,
												params->relid);

			if (numVectors > 0 && residency == 0)
				ereport(ERROR,
						(errcode(ERRCODE_INTERNAL_ERROR),
						 errmsg("build memory estimate for index %u is implausible",
								params->relid),
						 errdetail("SVS reported a zero-byte estimate for a %d-vector build.",
								   numVectors)));

			buildPeak = SvsBuildPeakCheckedAdd(residency, rawBuffer, params->relid);
			buildPeak = SvsBuildPeakCheckedAdd(buildPeak,
												(uint64) SvsDimBaselineBytes(params->dimensions),
												params->relid);

			term = (uint64) ceil(SvsDimAdjustmentMultiplier(params->dimensions) * (double) rawBuffer);
			buildPeak = SvsBuildPeakCheckedAdd(buildPeak, term, params->relid);

			if (params->compression_type == VAMANA_COMPRESSION_LEANVEC)
			{
				term = (uint64) ceil(SvsLeanVecExtraMultiplier(params->dimensions) * (double) rawBuffer);
				buildPeak = SvsBuildPeakCheckedAdd(buildPeak, term, params->relid);
			}

			/* Calibrated 15% margin; see VAMANA_BUILD_MEMORY_MARGIN_DIVISOR. */
			buildPeak = SvsBuildPeakCheckedAdd(buildPeak,
												buildPeak / VAMANA_BUILD_MEMORY_MARGIN_DIVISOR,
												params->relid);

			ereport(DEBUG1,
					(errmsg("build memory estimate for index %u", params->relid),
					 errdetail_log("graphBytes " UINT64_FORMAT ", dataBytes " UINT64_FORMAT
								   ", metadataBytes " UINT64_FORMAT
								   "; residency " UINT64_FORMAT ", rawBuffer " UINT64_FORMAT
								   "; buildPeak (margined) " UINT64_FORMAT " bytes.",
								   breakdown.graphBytes, breakdown.dataBytes,
								   breakdown.metadataBytes, residency, rawBuffer,
								   buildPeak)));

			SvsMemoryReserveBuild(MyDatabaseId, params->relid, buildPeak, residency);
			*buildPeakOut = buildPeak;
		}

		buildCtx = (VamanaSVSBuildContext) {
			.builder = builder,
			.flatData = flatData,
			.numVectors = numVectors,
			.graph_degree = params->graph_degree,
			.dimensions = params->dimensions,
		};

		SvsRunGovernedBuild(VamanaRunSVSBuild, &buildCtx);
	}
	PG_FINALLY();
	{
		SVSFreeBuilder(builder);
		SVSFreeStorage(storage);
		SVSFreeAlgorithm(algorithm);
	}
	PG_END_TRY();

	*errorCodeOut = buildCtx.errorCode;
	return buildCtx.result;
}

/*
 * Abort-cleanup callback for PG_ENSURE_ERROR_CLEANUP below.  Releases
 * whatever memory reservation arg's relid still holds, on every error
 * unwind spanning the build, the confirm, and the worker hand-off.
 *
 * Safe to call at any point in that span, including after a successful
 * hand-off: SvsMemoryAbortBuild leaves a RESIDENT reservation untouched and
 * restores a REBUILDING one to its pre-rebuild size rather than dropping
 * it, so "the reservation is gone, nothing left to release" is the wrong
 * mental model here and the one this comment exists to head off. It is
 * also safe when nothing was ever reserved (an error before the gate ran)
 * and when ConfirmBuild already released the build peak on this same
 * unwind: both leave nothing for it to find, and it is a no-op on a relid
 * with no reservation.
 */
static void
SvsBuildAbortCleanup(int code, Datum arg)
{
	SvsMemoryAbortBuild(MyDatabaseId, DatumGetObjectId(arg));
}

/*
 * Build the index
 */
IndexBuildResult *
vamanabuild(Relation heap, Relation index, IndexInfo *indexInfo)
{
	IndexBuildResult *result;
	VamanaBuildState buildstate;
	SVSIndexHandle volatile svsIndex = NULL;
	int			error_code;
	Oid			relid = RelationGetRelid(index);
	uint64		buildPeak = 0;

	/*
	 * Reject the build up front if this database is not enabled for vamana: the
	 * index could never be served here, and the check is a property of the
	 * database, not of the heap's contents.  Doing it before the scan also
	 * avoids wasting a full table scan on a permanent misconfiguration.
	 */
	VamanaWorkerAssertDatabase();

	InitBuildState(&buildstate, heap, index, indexInfo, MAIN_FORKNUM);

	SvsMemoryCheckEstimatedBuildSize(heap->rd_rel->reltuples, buildstate.dimensions);

	SvsVectorBufferInit(&buildstate.vectors, heap->rd_rel->reltuples, buildstate.dimensions);
	buildstate.tidBufferCapacity = buildstate.vectors.capacity;
	buildstate.tidBuffer = MemoryContextAllocHuge(CurrentMemoryContext, buildstate.tidBufferCapacity * sizeof(ItemPointerData));

	CreateMetaPage(&buildstate);

	pgstat_progress_update_param(PROGRESS_CREATEIDX_SUBPHASE, PROGRESS_VAMANA_PHASE_LOAD);
	buildstate.reltuples = table_index_build_scan(heap, index, indexInfo,
												  true, true, BuildCallback,
												  (void *) &buildstate, NULL);

	ereport(NOTICE,
			(errmsg("buffered %d vectors for SVS index build", (int) buildstate.vectors.count)));

	if (buildstate.compression_type == VAMANA_COMPRESSION_LEANVEC &&
		buildstate.vectors.count > 0 && buildstate.vectors.count < 100000)
	{
		ereport(WARNING,
				(errmsg("building LeanVec index with only %d vectors; "
						"recall may be poor (recommend >= 100000, minimum 10000)",
						(int) buildstate.vectors.count)));
	}
	else if (buildstate.compression_type == VAMANA_COMPRESSION_LVQ &&
			 buildstate.vectors.count > 0 && buildstate.vectors.count < 10000)
	{
		ereport(WARNING,
				(errmsg("building LVQ index with only %d vectors; "
						"recall may be poor (recommend >= 10000)",
						(int) buildstate.vectors.count)));
	}

	if (buildstate.vectors.count == 0)
	{
		ereport(NOTICE,
				(errmsg("no vectors to index, skipping SVS build")));

		/*
		 * Flush before invalidating: VamanaInvalidateCache signals the BGW,
		 * which may immediately open the new relfilenode.  RBM_NORMAL
		 * requires the page to already be on disk.
		 */
		FlushRelationBuffers(index);
		VamanaInvalidateCache(RelationGetRelid(index));

		goto cleanup;
	}

	ereport(NOTICE,
			(errmsg("building SVS index with %d vectors of dimension %d",
					(int) buildstate.vectors.count, buildstate.dimensions)));

	/*
	 * SvsBuildAbortCleanup releases whatever memory reservation this build
	 * holds, on an error unwind; it must span through the warm-up hand-off
	 * below because PG_TRY alone does not run on a FATAL exit, and the
	 * worker never independently learns of a caller-owned reservation.
	 */
	PG_ENSURE_ERROR_CLEANUP(SvsBuildAbortCleanup, ObjectIdGetDatum(relid));
	{
		uint64		measured;
		VamanaSVSIndexParams params = {
			.relid = relid,
			.dimensions = buildstate.dimensions,
			.graph_degree = buildstate.graph_degree,
			.alpha = buildstate.alpha,
			.build_window_size = buildstate.build_window_size,
			.search_window_size = buildstate.search_window_size,
			.use_search_history = buildstate.use_search_history,
			.compression_type = buildstate.compression_type,
			.compression_primary = buildstate.compression_primary,
			.compression_secondary = buildstate.compression_secondary,
			.leanvec_dims = buildstate.leanvec_dims,
			.distance_type = buildstate.distance_type,
			.data_type = buildstate.typeInfo->dataType,
		};

		svsIndex = VamanaBuildSVSIndexGoverned(&params, buildstate.vectors.data,
											   (int) buildstate.vectors.count,
											   buildstate.vectors.capacity, &error_code,
											   &buildPeak);

		if (svsIndex == NULL)
		{
			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("failed to build SVS index"),
					 errdetail_log("SVS error code: %d.", error_code),
					 errhint("Try increasing maintenance_work_mem or reducing vector dimensions.")));
		}

		ereport(NOTICE,
				(errmsg("SVS index built successfully")));

		/*
		 * Confirm before serializing: ConfirmBuild releases the build peak
		 * unconditionally and reconciles the residency reservation from
		 * estimate to this build's exact measured size. On rejection,
		 * ConfirmBuild has already dropped the reservation, so
		 * SvsBuildAbortCleanup finds nothing left for relid and is a
		 * no-op; freeing svsIndex here is this function's own job, since
		 * ConfirmBuild's contract is about accounting only, not about the
		 * native handle. ConfirmBuild can also ereport(ERROR) itself
		 * (no pending reservation, or one a concurrent ReconcileLoad
		 * already claimed to RESIDENT ahead of this call), which never
		 * reaches the fits-check below; svsIndex must be freed on that
		 * path too, not just on a plain false return.
		 */
		{
			bool	confirmed;

			measured = SVSGetIndexMemoryUsage(svsIndex);

			INJECTION_POINT("vamana-build-governed-pre-confirm", NULL);

			PG_TRY(Confirm);
			{
				confirmed = SvsMemoryConfirmBuild(MyDatabaseId, relid, buildPeak, measured);
			}
			PG_CATCH(Confirm);
			{
				SVSFreeIndex(svsIndex);
				PG_RE_THROW();
			}
			PG_END_TRY(Confirm);

			if (!confirmed)
			{
				SVSFreeIndex(svsIndex);
				ereport(ERROR,
						(errcode(ERRCODE_OUT_OF_MEMORY),
						 errmsg("build of index %u cannot be confirmed: exceeds this database's residency budget",
								relid),
						 errdetail("Measured %llu bytes.", (unsigned long long) measured)));
			}
		}

		/* Serialize index to disk so the BGW can adopt it. */
		SerializeIndexToPages(&buildstate, svsIndex);

		/*
		 * Hand off after serializing: the index is now durably on disk, so
		 * ownership of its measured bytes moves from "this backend, still
		 * fixable by an abort" to "this backend, pending only the worker's
		 * own load" (CONFIRMED -> HANDOFF). No byte accounting changes.
		 */
		SvsMemoryHandoffBuild(MyDatabaseId, relid);

		/*
		 * Synchronous warm-up: send a LOAD slot to the BGW so the index is in
		 * the worker cache before this transaction commits.  We read the
		 * authoritative values back from the metapage rather than using
		 * buildstate fields directly, because
		 * SerializeIndexToPages may have adjusted counters.
		 *
		 * leanvec_dims and distance_type are not stored on the metapage; read
		 * them from storage options / the AM support function.
		 */
		{
			VamanaMetaPageData meta;
			VamanaOptions  *opts = (VamanaOptions *) index->rd_options;

			VamanaReadMetaPage(index, &meta);

			if (VamanaWorkerIsAvailable())
			{
				INJECTION_POINT("vamana-build-governed-pre-handoff", NULL);
				if (!VamanaWorkerSubmitLoad(
						relid,
						(int) meta.dimensions,
						(int) meta.graph_degree,
						(int) meta.alpha,
						VamanaResolveSearchWindowSize(opts),
						(opts && opts->build_window_size > 0) ? opts->build_window_size : 0,
						(int) meta.compression_type,
						(int) meta.compression_primary,
						(int) meta.compression_secondary,
						opts ? opts->leanvec_dims : VAMANA_DEFAULT_LEANVEC_DIMS,
						(int) VamanaGetDistanceMetric(index),
						(int) buildstate.typeInfo->dataType,
						(int) meta.numVectors,
						(int) meta.tidMappingCapacity,
						meta.nextExternalId,
						(int) meta.numDeleted,
						RelationGetRelid(heap),
						index->rd_index->indkey.values[0] - 1))
				{
					/*
					 * The reservation stays in HANDOFF: the index is
					 * genuinely on disk, so this is correct, not a leak.
					 * SvsMemoryReapDeadReservations only reclaims RESERVED
					 * and REBUILDING reservations from a dead owner, since
					 * CONFIRMED and HANDOFF already have their bytes
					 * committed against real, durable resident data; the
					 * worker's own ReconcileLoad, on this index's next
					 * successful load, is what finally moves it to
					 * RESIDENT.
					 */
					ereport(WARNING,
							(errmsg("vamana index \"%s\": background worker load failed; "
									"index will be adopted by the worker on startup",
									RelationGetRelationName(index))));
				}

				/*
				 * A timed-out VamanaWorkerSubmitLoad does not rule out the
				 * worker having already created the slot before this
				 * backend gave up waiting; queuing is a safe no-op when it
				 * has not.
				 */
				VamanaReplicationQueueRetireOnAbort(MyDatabaseId, relid);
			}
			else
			{
				/* Same HANDOFF reasoning as the load-failure branch above. */
				ereport(WARNING,
						(errmsg("vamana index \"%s\": background worker not yet available; "
								"index will be adopted by the worker on startup",
								RelationGetRelationName(index))));
			}
		}

		/*
		 * Recorded after the warm-up attempt, not alongside the confirm it
		 * reports: SvsIndexResidencyRecordLoad holds a row lock on
		 * vamana_databases until this transaction ends, and taking it
		 * before VamanaWorkerSubmitLoad self-deadlocks against
		 * VamanaCacheIndex needing that same lock to finish the load this
		 * backend is waiting on. Recording afterward still guarantees a
		 * durable record in this transaction regardless of whether the
		 * worker ever loads the index.
		 */
		SvsIndexResidencyRecordLoad(relid, MyDatabaseId, measured);
	}
	PG_END_ENSURE_ERROR_CLEANUP(SvsBuildAbortCleanup, ObjectIdGetDatum(relid));

cleanup:
	if (svsIndex)
		SVSFreeIndex(svsIndex);

	FreeBuildState(&buildstate);

	/* WAL logging - must be done even for empty indexes */
	if (RelationNeedsWAL(index))
	{
		log_newpage_range(index, MAIN_FORKNUM, 0,
						  RelationGetNumberOfBlocks(index), true);
	}

	result = (IndexBuildResult *) palloc(sizeof(IndexBuildResult));
	result->heap_tuples = buildstate.reltuples;
	result->index_tuples = buildstate.vectors.count;

	return result;
}

/*
 * Build empty index (for unlogged tables)
 */
void
vamanabuildempty(Relation index)
{
	VamanaBuildState buildstate;
	IndexInfo  *indexInfo = BuildIndexInfo(index);

	InitBuildState(&buildstate, NULL, index, indexInfo, INIT_FORKNUM);
	CreateMetaPage(&buildstate);

	/*
	 * Flush before invalidating: VamanaInvalidateCache signals the BGW,
	 * which may immediately open the new relfilenode.  RBM_NORMAL requires
	 * the page to already be on disk.
	 */
	FlushRelationBuffers(index);
	VamanaInvalidateCache(RelationGetRelid(index));

	MemoryContextDelete(buildstate.buildCtx);
	MemoryContextDelete(buildstate.tmpCtx);
}

/*
 * Rebuild SVS index from table data
 * This is called when the index is not cached (e.g., after server restart)
 */
SVSIndexHandle
VamanaRebuildFromTable(Relation index)
{
	Relation	heap;
	TableScanDesc heapScan;
	HeapTuple	tuple;
	TupleDesc	tupdesc;
	SVSIndexHandle volatile svsIndex;
	VamanaOptions *opts;
	const		VamanaTypeInfo *typeInfo;
	int			dimensions;
	int			graph_degree;
	int			alpha;
	int			buildWindow;
	int			searchWindow;
	bool		useSearchHistory;
	SVSDistanceType distanceType;
	int			compression_type;
	int			compression_primary;
	int			compression_secondary;
	int			leanvec_dims;
	Snapshot	snapshot;
	SvsVectorBuffer vectors = {0};
	ItemPointerData *tidMapping = NULL;
	int64		tidBufferCapacity = 0;
	int			errorCode = 0;
	Oid			relid = RelationGetRelid(index);
	uint64		buildPeak = 0;

	ereport(LOG,
			(errmsg("rebuilding vamana index from table data")));

	opts = (VamanaOptions *) index->rd_options;
	typeInfo = VamanaGetTypeInfo(index);
	dimensions = TupleDescAttr(index->rd_att, 0)->atttypmod;
	graph_degree = opts ? opts->graph_degree : VAMANA_DEFAULT_GRAPH_DEGREE;
	alpha = opts ? opts->alpha : VAMANA_DEFAULT_ALPHA;
	buildWindow = (opts && opts->build_window_size > 0) ?
		opts->build_window_size : VAMANA_BUILD_WINDOW_FROM_DEGREE(graph_degree);
	searchWindow = VamanaResolveSearchWindowSize(opts);
	useSearchHistory = opts ? opts->use_search_history : VAMANA_DEFAULT_USE_SEARCH_HISTORY;
	compression_type = opts ? opts->compression_type : VAMANA_DEFAULT_COMPRESSION_TYPE;
	compression_primary = opts ? opts->compression_primary : VAMANA_DEFAULT_COMPRESSION_PRIMARY;
	compression_secondary = opts ? opts->compression_secondary : VAMANA_DEFAULT_COMPRESSION_SECONDARY;
	leanvec_dims = opts ? opts->leanvec_dims : VAMANA_DEFAULT_LEANVEC_DIMS;

	distanceType = VamanaGetDistanceMetric(index);

	/*
	 * Acquire AccessShareLock on the heap non-blocking.  The BGW must never
	 * block on a relation-level lock: holding ASL on the index (acquired by
	 * VamanaWorkerGetOrLoadIndex) while blocking on the heap creates a
	 * lock-ordering cycle with DROP TABLE, which takes AEL on the heap then
	 * AEL on the index.  This mirrors the autovacuum pattern.
	 */
	if (!ConditionalLockRelationOid(index->rd_index->indrelid, AccessShareLock))
	{
		ereport(LOG,
				(errmsg("vamana index %u: heap locked by DDL, skipping rebuild",
						RelationGetRelid(index))));
		return NULL;
	}

	heap = table_open(index->rd_index->indrelid, NoLock);
	tupdesc = RelationGetDescr(heap);

	SvsMemoryCheckEstimatedBuildSize(heap->rd_rel->reltuples, dimensions);

	SvsVectorBufferInit(&vectors, heap->rd_rel->reltuples, dimensions);
	tidBufferCapacity = vectors.capacity;
	tidMapping = MemoryContextAllocHuge(CurrentMemoryContext, tidBufferCapacity * sizeof(ItemPointerData));

	/*
	 * Scan table to collect vectors - use an MVCC snapshot to exclude dead
	 * tuples
	 */
	snapshot = RegisterSnapshot(GetTransactionSnapshot());
	heapScan = table_beginscan(heap, snapshot, 0, NULL);

	while ((tuple = heap_getnext(heapScan, ForwardScanDirection)) != NULL)
	{
		Datum	   *values;
		bool	   *isnull;
		float	   *floats;
		int			datumDim;
		int			natts = tupdesc->natts;
		int			vectorAttNum;

		values = (Datum *) palloc(natts * sizeof(Datum));
		isnull = (bool *) palloc(natts * sizeof(bool));

		heap_deform_tuple(tuple, tupdesc, values, isnull);

		/* Find which attribute is the indexed vector column */
		vectorAttNum = index->rd_index->indkey.values[0] - 1;	/* Attribute numbers are
																 * 1-based */

		if (!isnull[vectorAttNum])
		{
			floats = VamanaDatumToFloats(typeInfo, values[vectorAttNum],
										 &datumDim, "rebuild");
			if (datumDim != dimensions)
			{
				pfree(floats);
				pfree(values);
				pfree(isnull);
				ereport(ERROR,
						(errcode(ERRCODE_DATA_EXCEPTION),
						 errmsg("vector dimension mismatch: expected %d, got %d", dimensions, datumDim)));
			}

			SvsVectorBufferAppend(&vectors, floats);
			pfree(floats);

			if (tidBufferCapacity < vectors.capacity)
			{
				tidBufferCapacity = vectors.capacity;
				tidMapping = repalloc_huge(tidMapping,
									  tidBufferCapacity * sizeof(ItemPointerData));
			}
			ItemPointerCopy(&tuple->t_self, &tidMapping[vectors.count - 1]);

			/*
			 * Emit progress LOG at regular intervals to surface progress during
			 * long-running rebuilds.
			 */
			if (vectors.count % VAMANA_PROGRESS_INTERVAL == 0)
				ereport(LOG,
						(errmsg("vamana index %u: scanning table, %d vectors collected",
								RelationGetRelid(index), (int) vectors.count)));
		}

		pfree(values);
		pfree(isnull);

		CHECK_FOR_INTERRUPTS();
	}

	table_endscan(heapScan);
	UnregisterSnapshot(snapshot);
	table_close(heap, NoLock);
	UnlockRelationOid(index->rd_index->indrelid, AccessShareLock);

	if (vectors.count == 0)
	{
		ereport(WARNING,
				(errmsg("no vectors found in table for index rebuild")));
		pfree(tidMapping);
		SvsVectorBufferFree(&vectors);
		return NULL;
	}

	ereport(NOTICE,
			(errmsg("collected %d vectors, building SVS index...", (int) vectors.count)));

	if (compression_type == VAMANA_COMPRESSION_LEANVEC &&
		vectors.count < 100000)
	{
		ereport(WARNING,
				(errmsg("rebuilding LeanVec index with only %d vectors; "
						"recall may be poor (recommend >= 100000, minimum 10000)",
						(int) vectors.count)));
	}
	else if (compression_type == VAMANA_COMPRESSION_LVQ &&
			 vectors.count < 10000)
	{
		ereport(WARNING,
				(errmsg("rebuilding LVQ index with only %d vectors; "
						"recall may be poor (recommend >= 10000)",
						(int) vectors.count)));
	}

	/*
	 * SvsBuildAbortCleanup releases whatever memory reservation this build
	 * holds, on an error unwind; it must span through VamanaCacheIndex
	 * below, the point at which the index is durably tracked and hand-off
	 * to the worker is complete, mirroring vamanabuild()'s own span.  The
	 * release happens here, in the caller, rather than inside
	 * VamanaBuildSVSIndexGoverned, because only the caller knows when
	 * hand-off has completed.
	 */
	PG_ENSURE_ERROR_CLEANUP(SvsBuildAbortCleanup, ObjectIdGetDatum(relid));
	{
		VamanaSVSIndexParams params = {
			.relid = relid,
			.dimensions = dimensions,
			.graph_degree = graph_degree,
			.alpha = alpha,
			.build_window_size = buildWindow,
			.search_window_size = searchWindow,
			.use_search_history = useSearchHistory,
			.compression_type = compression_type,
			.compression_primary = compression_primary,
			.compression_secondary = compression_secondary,
			.leanvec_dims = leanvec_dims,
			.distance_type = distanceType,
			.data_type = typeInfo->dataType,
		};

		int			numVectors = (int) vectors.count;

		svsIndex = VamanaBuildSVSIndexGoverned(&params, vectors.data,
												numVectors, vectors.capacity,
												&errorCode, &buildPeak);

		if (svsIndex == NULL || errorCode != 0)
		{
			SvsVectorBufferFree(&vectors);

			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("failed to rebuild vamana index from table"),
					 errdetail("SVS build failed with error code %d.", errorCode)));
		}

		SVSSetIndexSearchThreads(svsIndex, SvsCurrentSearchGrant());

		/* tidMapping is still needed below, by VamanaCacheIndex. */
		SvsVectorBufferFree(&vectors);

		ereport(NOTICE,
				(errmsg("successfully rebuilt vamana index with %d vectors", numVectors)));

		/*
		 * Confirm before caching: releases the build peak unconditionally
		 * and reconciles the residency reservation from estimate to this
		 * rebuild's exact measured size, same as vamanabuild()'s own
		 * confirm. There is no separate serialize step on this path --
		 * VamanaCacheIndex below is both the durable record and the
		 * hand-off point -- so confirm-then-handoff here is a pure
		 * bookkeeping step, not a second admission gate: ReconcileLoad
		 * inside VamanaCacheIndex is state-agnostic and would reconcile a
		 * RESERVED reservation just as well as a HANDOFF one. It still
		 * runs, to keep one state machine for every build path and to fail
		 * on this rebuild's measured bytes before caching rather than
		 * inside it. ConfirmBuild can also ereport(ERROR) itself (see
		 * vamanabuild()'s own confirm for why); svsIndex must be freed on
		 * that path too, not just on a plain false return.
		 */
		{
			uint64		measured = SVSGetIndexMemoryUsage(svsIndex);
			bool		confirmed;

			INJECTION_POINT("vamana-build-governed-pre-confirm", NULL);

			PG_TRY(Confirm);
			{
				confirmed = SvsMemoryConfirmBuild(MyDatabaseId, relid, buildPeak, measured);
			}
			PG_CATCH(Confirm);
			{
				SVSFreeIndex(svsIndex);
				PG_RE_THROW();
			}
			PG_END_TRY(Confirm);

			if (!confirmed)
			{
				SVSFreeIndex(svsIndex);
				ereport(ERROR,
						(errcode(ERRCODE_OUT_OF_MEMORY),
						 errmsg("build of index %u cannot be confirmed: exceeds this database's residency budget",
								relid),
						 errdetail("Measured %llu bytes.", (unsigned long long) measured)));
			}
		}

		SvsMemoryHandoffBuild(MyDatabaseId, relid);

		/*
		 * Cache the rebuilt index with TID mapping and dynamic fields.
		 * VamanaCacheIndex measures svsIndex itself and calls
		 * SvsMemoryReconcileLoad (HANDOFF -> RESIDENT) and
		 * SvsIndexResidencyRecordLoad on every caller's behalf, so this
		 * path does not repeat either call.
		 */
		INJECTION_POINT("vamana-build-governed-pre-handoff", NULL);
		VamanaCacheIndex(relid, svsIndex, dimensions,
						 graph_degree, VAMANA_ALPHA_TO_FLOAT(alpha), tidMapping, numVectors,
						 numVectors,	/* tidMappingCapacity (fresh rebuild, no
										 * holes) */
						 (uint64) numVectors,	/* nextExternalId */
						 0);		/* numDeleted */
	}
	PG_END_ENSURE_ERROR_CLEANUP(SvsBuildAbortCleanup, ObjectIdGetDatum(relid));

	return svsIndex;
}
