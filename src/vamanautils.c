/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamanautils.c
 *
 * Type info, support functions, buffer/page management, metapage operations,
 * reloptions, cost estimation, and distance metric helpers for Vamana index.
 *
 * On-disk I/O lives in vamanaio.c.
 * Per-process index cache lives in vamanacache.c.
 * Index rebuild from table lives in vamanabuild.c.
 */

#include "postgres.h"

#include "vamana.h"

#include "access/amapi.h"
#include "access/generic_xlog.h"
#include "access/reloptions.h"
#include "catalog/pg_type_d.h"
#include "commands/progress.h"
#include "miscadmin.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"
#include "utils/selfuncs.h"

/*
 * Get type-specific information
 */
const		VamanaTypeInfo *
VamanaGetTypeInfo(Relation index)
{
	static const VamanaTypeInfo vector_info = {
		.maxDimensions = VAMANA_MAX_DIM
	};

	return &vector_info;
}

/*
 * Initialize support functions for the index
 */
void
VamanaInitSupport(VamanaSupport * support, Relation index)
{
	FmgrInfo   *procinfo;

	procinfo = index_getprocinfo(index, 1, VAMANA_DISTANCE_PROC);
	support->procinfo = procinfo;

	support->collation = index->rd_indcollation[0];

	support->normprocinfo = VamanaOptionalProcInfo(index, VAMANA_NORM_PROC);
}

/*
 * Get optional support function
 */
FmgrInfo *
VamanaOptionalProcInfo(Relation index, uint16 procnum)
{
	if (!OidIsValid(index_getprocid(index, 1, procnum)))
		return NULL;

	return index_getprocinfo(index, 1, procnum);
}

/*
 * Allocate a new buffer for the index
 */
Buffer
VamanaNewBuffer(Relation index, ForkNumber forkNum)
{
	Buffer		buf = ReadBufferExtended(index, forkNum, P_NEW, RBM_NORMAL, NULL);

	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);

	return buf;
}

/*
 * Initialize a new page
 */
void
VamanaInitPage(Buffer buf, Page page)
{
	PageInit(page, BufferGetPageSize(buf), sizeof(VamanaPageOpaqueData));
	VamanaPageGetOpaque(page)->nextblkno = InvalidBlockNumber;
	VamanaPageGetOpaque(page)->page_id = VAMANA_PAGE_ID;
}

/*
 * Update the metapage with index information
 */
void
VamanaUpdateMetaPage(Relation index, BlockNumber indexDataBlkno,
					 Size indexDataSize, uint32 numVectors, ForkNumber forkNum)
{
	Buffer		buf;
	Page		page;
	GenericXLogState *state;
	VamanaMetaPage metap;

	buf = ReadBufferExtended(index, forkNum, VAMANA_METAPAGE_BLKNO,
							 RBM_NORMAL, NULL);
	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
	state = GenericXLogStart(index);
	page = GenericXLogRegisterBuffer(state, buf, 0);
	metap = VamanaPageGetMeta(page);

	metap->indexDataBlkno = indexDataBlkno;
	metap->indexDataSize = indexDataSize;
	metap->numVectors = numVectors;

	GenericXLogFinish(state);
	UnlockReleaseBuffer(buf);
}

/*
 * Get metapage information
 */
void
VamanaGetMetaPageInfo(Relation index, int *graph_degree, int *dimensions)
{
	Buffer		buf;
	Page		page;
	VamanaMetaPage metap;

	buf = ReadBuffer(index, VAMANA_METAPAGE_BLKNO);
	LockBuffer(buf, BUFFER_LOCK_SHARE);
	page = BufferGetPage(buf);
	metap = VamanaPageGetMeta(page);

	if (graph_degree)
		*graph_degree = metap->graph_degree;
	if (dimensions)
		*dimensions = metap->dimensions;

	UnlockReleaseBuffer(buf);
}

/*
 * Read the full metapage into a caller-supplied struct.
 */
void
VamanaReadMetaPage(Relation index, VamanaMetaPageData * meta)
{
	Buffer		buf;
	Page		page;
	VamanaMetaPage metap;

	buf = ReadBufferExtended(index, MAIN_FORKNUM, VAMANA_METAPAGE_BLKNO,
							 RBM_NORMAL, NULL);
	LockBuffer(buf, BUFFER_LOCK_SHARE);
	page = BufferGetPage(buf);
	metap = VamanaPageGetMeta(page);
	memcpy(meta, metap, sizeof(VamanaMetaPageData));
	UnlockReleaseBuffer(buf);
}

/*
 * Write dynamic index fields to the metapage under GenericXLog.
 * Called after a successful SVSAddPoints or SVSDeletePoints to persist
 * nextExternalId, numVectors, numDeleted, and tidMappingCapacity atomically.
 */
void
VamanaWriteMetaPageDynamic(Relation index, uint64 nextExternalId,
						   uint32 numVectors, uint32 numDeleted,
						   uint32 tidMappingCapacity, ForkNumber forkNum)
{
	Buffer		buf;
	Page		page;
	GenericXLogState *state;
	VamanaMetaPage metap;

	buf = ReadBufferExtended(index, forkNum, VAMANA_METAPAGE_BLKNO,
							 RBM_NORMAL, NULL);
	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
	state = GenericXLogStart(index);
	page = GenericXLogRegisterBuffer(state, buf, 0);
	metap = VamanaPageGetMeta(page);

	metap->nextExternalId = nextExternalId;
	metap->numVectors = numVectors;
	metap->numDeleted = numDeleted;
	metap->tidMappingCapacity = tidMappingCapacity;

	GenericXLogFinish(state);
	UnlockReleaseBuffer(buf);
}

/*
 * Build reloptions for Vamana index
 */
extern relopt_kind vamana_relopt_kind;

bytea *
vamanaoptions(Datum reloptions, bool validate)
{
	static const relopt_parse_elt tab[] = {
		{"graph_degree", RELOPT_TYPE_INT, offsetof(VamanaOptions, graph_degree)},
		{"alpha", RELOPT_TYPE_INT, offsetof(VamanaOptions, alpha)},
		{"build_window_size", RELOPT_TYPE_INT, offsetof(VamanaOptions, build_window_size)},
		{"search_window_size", RELOPT_TYPE_INT, offsetof(VamanaOptions, search_window_size)},
		{"use_search_history", RELOPT_TYPE_BOOL, offsetof(VamanaOptions, use_search_history)},
		{"compression_type", RELOPT_TYPE_INT, offsetof(VamanaOptions, compression_type)},
		{"compression_primary", RELOPT_TYPE_INT, offsetof(VamanaOptions, compression_primary)},
		{"compression_secondary", RELOPT_TYPE_INT, offsetof(VamanaOptions, compression_secondary)},
		{"leanvec_dims", RELOPT_TYPE_INT, offsetof(VamanaOptions, leanvec_dims)}
	};

	return (bytea *) build_reloptions(reloptions, validate,
									  vamana_relopt_kind,
									  sizeof(VamanaOptions),
									  tab, lengthof(tab));
}

void
vamanacostestimate(PlannerInfo *root, IndexPath *path, double loop_count,
				   Cost *indexStartupCost, Cost *indexTotalCost,
				   Selectivity *indexSelectivity, double *indexCorrelation,
				   double *indexPages)
{
	GenericCosts costs;

	MemSet(&costs, 0, sizeof(costs));
	genericcostestimate(root, path, loop_count, &costs);

	/* Scale down generic cost estimate to reflect ANN index characteristics */
	costs.indexTotalCost *= VAMANA_COST_SCALING_FACTOR;

	*indexStartupCost = costs.indexStartupCost;
	*indexTotalCost = costs.indexTotalCost;
	*indexSelectivity = costs.indexSelectivity;
	*indexCorrelation = costs.indexCorrelation;
	*indexPages = costs.numIndexPages;
}

/*
 * Get readable name for build phase
 */
char *
vamanabuildphasename(int64 phaseNum)
{
	switch (phaseNum)
	{
		case PROGRESS_CREATEIDX_SUBPHASE_INITIALIZE:
			return "initializing";
		case PROGRESS_VAMANA_PHASE_LOAD:
			return "loading tuples";
		default:
			return NULL;
	}
}

/*
 * Validate index definition
 */
bool
vamanavalidate(Oid opclassoid)
{
	return true;
}

/*
 * Distance metric helper
 */

/*
 * Determine the SVS distance metric from the index's operator class.
 * Inspects support function names to distinguish L2 / cosine / inner-product.
 */
SVSDistanceType
VamanaGetDistanceMetric(Relation index)
{
	Oid			opfamilyoid;
	Oid			inputTypeOid;
	Oid			distanceFuncOid;
	char	   *funcName;

	opfamilyoid = index->rd_opfamily[0];
	inputTypeOid = index->rd_opcintype[0];

	distanceFuncOid = get_opfamily_proc(opfamilyoid, inputTypeOid, inputTypeOid,
										VAMANA_DISTANCE_PROC);
	if (!OidIsValid(distanceFuncOid))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("no distance function found for vamana index"),
				 errhint("Ensure you are using vector_l2_ops, vector_ip_ops, or vector_cosine_ops")));

	funcName = get_func_name(distanceFuncOid);
	if (funcName == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("could not determine distance function name")));

	if (strcmp(funcName, "vector_l2_squared_distance") == 0 ||
		strcmp(funcName, "halfvec_l2_squared_distance") == 0)
	{
		pfree(funcName);
		return SVS_DISTANCE_L2;
	}

	if (strcmp(funcName, "vector_negative_inner_product") == 0 ||
		strcmp(funcName, "halfvec_negative_inner_product") == 0)
	{
		/*
		 * Inner-product op class doubles as cosine when a norm function is
		 * registered (support function 2).
		 */
		Oid			normFuncOid = get_opfamily_proc(opfamilyoid, inputTypeOid,
													inputTypeOid,
													VAMANA_NORM_PROC);
		SVSDistanceType result;

		result = OidIsValid(normFuncOid) ? SVS_DISTANCE_COSINE : SVS_DISTANCE_IP;
		pfree(funcName);
		return result;
	}

	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("unsupported distance function for vamana index: %s", funcName),
			 errhint("Use vector_l2_ops, vector_ip_ops, or vector_cosine_ops")));
	return SVS_DISTANCE_L2;		/* unreachable */
}

/*
 * Reject vectors containing NaN or Inf before passing them to the SVS
 * library. SVS performs no input validation; non-finite values propagate
 * silently through distance computations (IEEE 754), corrupting k-NN
 * ranking without error. context is a short label used in the error
 * message ("insert", "query", "build").
 */
void
VamanaValidateVectorData(const float *data, int dim, const char *context)
{
	for (int i = 0; i < dim; i++)
	{
		if (isnan(data[i]) || isinf(data[i]))
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("vector contains invalid floating-point value "
							"(NaN or Infinity) at position %d in %s",
							i, context)));
	}
}
