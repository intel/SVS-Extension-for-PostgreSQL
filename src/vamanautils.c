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

#include <math.h>

#include "vamana.h"

#include "access/amapi.h"
#include "access/amvalidate.h"
#include "access/generic_xlog.h"
#include "access/htup_details.h"
#include "access/reloptions.h"
#include "catalog/dependency.h"
#include "catalog/pg_amop.h"
#include "catalog/pg_amproc.h"
#include "catalog/pg_opclass.h"
#include "catalog/pg_type.h"
#include "catalog/pg_type_d.h"
#include "commands/extension.h"
#include "commands/progress.h"
#include "miscadmin.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "utils/builtins.h"
#include "utils/float.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/regproc.h"
#include "utils/rel.h"
#include "utils/syscache.h"
#include "utils/selfuncs.h"

/* The supported indexed types, one descriptor each. */
static const VamanaTypeInfo vector_info = {
	.maxDimensions = VAMANA_MAX_DIM,
	.elementSize = sizeof(float),
	.dataType = SVS_DTYPE_FLOAT32
};
static const VamanaTypeInfo halfvec_info = {
	.maxDimensions = VAMANA_MAX_DIM,
	.elementSize = sizeof(half),
	.dataType = SVS_DTYPE_FLOAT16
};

/*
 * Classify a type OID as one of the types a vamana index can store, without
 * erroring. Returns NULL if typeOid is neither.
 *
 * Compared by name through the syscache rather than by OID: pgvector's type
 * OIDs are assigned at CREATE EXTENSION and are not fixed. Shared by
 * VamanaGetTypeInfo (the hot runtime path, called per build/insert/scan) and
 * vamanavalidate (called rarely, only through the SQL amvalidate(oid)
 * function), so the two cannot drift apart on what counts as a supported
 * type.
 */
static const VamanaTypeInfo *
SvsClassifyIndexedType(Oid typeOid)
{
	HeapTuple	typeTup;
	char	   *typname;
	const VamanaTypeInfo *result = NULL;

	typeTup = SearchSysCache1(TYPEOID, ObjectIdGetDatum(typeOid));
	if (!HeapTupleIsValid(typeTup))
		elog(ERROR, "cache lookup failed for type %u", typeOid);

	typname = NameStr(((Form_pg_type) GETSTRUCT(typeTup))->typname);

	if (strcmp(typname, "vector") == 0)
		result = &vector_info;
	else if (strcmp(typname, "halfvec") == 0)
		result = &halfvec_info;

	ReleaseSysCache(typeTup);

	return result;
}

/*
 * Get type-specific information for the indexed column.
 *
 * Resolved from the attribute's type rather than assumed, because vector and
 * halfvec share an identical varlena header and differ only in element width:
 * reading one as the other is not caught by any size check the datum itself
 * carries.
 */
const		VamanaTypeInfo *
VamanaGetTypeInfo(Relation index)
{
	Oid			atttypid = TupleDescAttr(RelationGetDescr(index), 0)->atttypid;
	const VamanaTypeInfo *result = SvsClassifyIndexedType(atttypid);

	if (result == NULL)
	{
		HeapTuple	typeTup = SearchSysCache1(TYPEOID, ObjectIdGetDatum(atttypid));
		char	   *unsupported;

		if (!HeapTupleIsValid(typeTup))
			elog(ERROR, "cache lookup failed for type %u", atttypid);

		unsupported = pstrdup(NameStr(((Form_pg_type) GETSTRUCT(typeTup))->typname));
		ReleaseSysCache(typeTup);

		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("unsupported type for vamana index: %s", unsupported),
				 errhint("A vamana index supports the vector and halfvec types.")));
	}

	return result;
}

/*
 * Check that typeOid is actually provided by the "vector" extension, not
 * merely named "vector"/"halfvec" by some other extension. Name-only
 * classification (SvsClassifyIndexedType) is what the runtime path uses,
 * since it runs per build/insert/scan and a pg_depend lookup there would add
 * cost to every one of those calls. amvalidate has exactly one caller
 * (the SQL function amvalidate(oid), see access/index/amapi.c) and is never
 * on a hot path, so the extra identity check is free here and closes the
 * gap the name-only check leaves open.
 */
static bool
SvsTypeIsFromVectorExtension(Oid typeOid)
{
	Oid			vectorExtOid = get_extension_oid("vector", true);

	if (!OidIsValid(vectorExtOid))
		return false;

	return getExtensionOfObject(TypeRelationId, typeOid) == vectorExtOid;
}

/*
 * Get type-specific information from an SVS storage element type.
 *
 * For the background worker, which populates cache entries from the load
 * parameters a backend handed it and so has no index relation to inspect.  The
 * mapping is one-to-one because each supported type has its own dataType.
 */
const		VamanaTypeInfo *
VamanaGetTypeInfoForDataType(SVSDType dataType)
{
	switch (dataType)
	{
		case SVS_DTYPE_FLOAT32:
			return &vector_info;
		case SVS_DTYPE_FLOAT16:
			return &halfvec_info;
		default:
			elog(ERROR, "unsupported vamana storage data type: %d", (int) dataType);
			return NULL;
	}
}

/*
 * Convert a binary16 bit pattern to float.
 *
 * pgvector's HalfToFloat4 lives in its halfutils.h, which pgvector does not
 * install, so this is the same conversion carried locally (pgvector is under
 * the PostgreSQL licence, as is this file).  pgvector also has an _cvtsh_ss
 * path for F16C hardware; this keeps the portable arithmetic instead, which is
 * exact for every input including subnormals, infinities and NaN, so the result
 * does not depend on which of halfvec.h's three configurations the build picked.
 * The cast is the right conversion in exactly the one configuration where half
 * is a native _Float16.
 */
static inline float
VamanaHalfToFloat4(half num)
{
#ifdef FLT16_SUPPORT
	return (float) num;
#else
	uint16		bits = (uint16) num;
	uint16		sign = (bits >> 15) & 0x0001;
	uint16		expo = (bits >> 10) & 0x001F;
	uint16		mant = bits & 0x03FF;
	uint32		result;

	if (expo == 0)
	{
		if (mant == 0)
		{
			/* +-zero */
			result = (uint32) sign << 31;
		}
		else
		{
			/* subnormal: renormalize into a float32 normal */
			int			shift = 0;

			while ((mant & 0x0400) == 0)
			{
				mant <<= 1;
				shift++;
			}
			mant &= 0x03FF;

			result = ((uint32) sign << 31)
				| ((uint32) (127 - 15 - shift) << 23)
				| ((uint32) mant << 13);
		}
	}
	else if (expo == 0x1F)
	{
		/* Inf or NaN; a non-zero mantissa stays non-zero, so NaN stays NaN */
		result = ((uint32) sign << 31) | 0x7F800000 | ((uint32) mant << 13);
	}
	else
	{
		result = ((uint32) sign << 31)
			| ((uint32) (expo - 15 + 127) << 23)
			| ((uint32) mant << 13);
	}

	return *((float *) &result);
#endif
}

/*
 * Read an indexed datum into a freshly palloc'd float array.
 *
 * Every SVS entry point takes float32, so this is the one place a stored
 * element width turns into the float buffer the rest of the extension works
 * in.  Detoasting with _COPY keeps the elements in their own palloc block:
 * without it SVS's aligned reads can overshoot the heap-page buffer.
 *
 * The varlena size is checked against the header plus dim elements of the
 * *indexed* type before any element is touched, so a datum of another width
 * is rejected with an error rather than misread.  dim is an output, mirroring
 * the datum's own dimension rather than the index's.
 */
float *
VamanaDatumToFloats(const VamanaTypeInfo *typeInfo, Datum datum,
					int *dim, const char *context)
{
	struct varlena *raw = (struct varlena *) PG_DETOAST_DATUM_COPY(datum);
	int16		datumDim;
	Size		expectedSize;
	float	   *result;

	/*
	 * vector and halfvec share this header layout exactly (int32 vl_len_,
	 * int16 dim, int16 unused), so the dimension can be read before the
	 * element type is known.
	 */
	datumDim = ((Vector *) raw)->dim;

	if (datumDim < 0)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("vector has negative dimension %d in %s",
						datumDim, context)));

	expectedSize = offsetof(Vector, x) + (Size) datumDim * typeInfo->elementSize;

	if (VARSIZE_ANY_EXHDR(raw) + VARHDRSZ != expectedSize)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("vector datum size %u does not match %d dimensions in %s",
						(unsigned) VARSIZE_ANY(raw), datumDim, context)));

	result = (float *) palloc((Size) datumDim * sizeof(float));

	if (typeInfo->elementSize == sizeof(float))
		memcpy(result, ((Vector *) raw)->x, (Size) datumDim * sizeof(float));
	else
	{
		half	   *elems = ((HalfVector *) raw)->x;

		for (int i = 0; i < datumDim; i++)
			result[i] = VamanaHalfToFloat4(elems[i]);
	}

	pfree(raw);

	VamanaValidateVectorData(result, datumDim, context);

	*dim = datumDim;

	return result;
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
	/* vector dimension counts are far below INT_MAX; cast makes the narrowing explicit */
	if (dimensions)
		*dimensions = (int) metap->dimensions;

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

	if (meta->magicNumber != VAMANA_MAGIC_NUMBER)
		ereport(ERROR,
				(errcode(ERRCODE_DATA_CORRUPTED),
				 errmsg("vamana index \"%s\" was built with an incompatible on-disk format",
						RelationGetRelationName(index)),
				 errhint("REINDEX this index.")));
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

	/*
	 * A vamana scan with no ORDER BY has no query vector to search with, so
	 * vamanagettuple cannot return real results (see its own guard). Make
	 * such a path look infinitely expensive so the planner never prefers it
	 * over a seqscan, mirroring pgvector's hnswcostestimate/ivfflatcostestimate.
	 */
	if (path->indexorderbys == NIL)
	{
		*indexStartupCost = get_float8_infinity();
		*indexTotalCost = get_float8_infinity();
		*indexSelectivity = 0;
		*indexCorrelation = 0;
		*indexPages = 0;
#if PG_VERSION_NUM >= 180000
		/* See "On disable_cost" thread on pgsql-hackers. */
		path->path.disabled_nodes = 2;
#endif
		return;
	}

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
 * Distance metric helper
 */

/*
 * Classify the distance metric a (opfamily, inputType) pair maps to, without
 * erroring. Inspects the support-function-1 name to distinguish
 * L2 / cosine / inner-product, same as the runtime path. Returns false if
 * there is no support function 1, or its name maps to no known metric;
 * *metric is only set on success.
 *
 * Shared by VamanaGetDistanceMetric (the hot runtime path, called at build
 * and by the worker) and vamanavalidate, so the two cannot drift on what
 * counts as a supported distance function.
 */
static bool
SvsClassifyDistanceMetric(Oid opfamilyoid, Oid inputTypeOid, SVSDistanceType *metric)
{
	Oid			distanceFuncOid;
	char	   *funcName;
	bool		ok = false;

	distanceFuncOid = get_opfamily_proc(opfamilyoid, inputTypeOid, inputTypeOid,
										VAMANA_DISTANCE_PROC);
	if (!OidIsValid(distanceFuncOid))
		return false;

	funcName = get_func_name(distanceFuncOid);
	if (funcName == NULL)
		return false;

	if (strcmp(funcName, "vector_l2_squared_distance") == 0 ||
		strcmp(funcName, "halfvec_l2_squared_distance") == 0)
	{
		*metric = SVS_DISTANCE_L2;
		ok = true;
	}
	else if (strcmp(funcName, "vector_negative_inner_product") == 0 ||
			 strcmp(funcName, "halfvec_negative_inner_product") == 0)
	{
		/*
		 * Inner-product op class doubles as cosine when a norm function is
		 * registered (support function 2).
		 */
		Oid			normFuncOid = get_opfamily_proc(opfamilyoid, inputTypeOid,
													inputTypeOid,
													VAMANA_NORM_PROC);

		*metric = OidIsValid(normFuncOid) ? SVS_DISTANCE_COSINE : SVS_DISTANCE_IP;
		ok = true;
	}

	pfree(funcName);
	return ok;
}

/*
 * Determine the SVS distance metric from the index's operator class.
 * Inspects support function names to distinguish L2 / cosine / inner-product.
 */
SVSDistanceType
VamanaGetDistanceMetric(Relation index)
{
	Oid			opfamilyoid = index->rd_opfamily[0];
	Oid			inputTypeOid = index->rd_opcintype[0];
	SVSDistanceType result;

	if (!OidIsValid(get_opfamily_proc(opfamilyoid, inputTypeOid, inputTypeOid,
									  VAMANA_DISTANCE_PROC)))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("no distance function found for vamana index"),
				 errhint("Ensure you are using vector_l2_ops, vector_ip_ops, or vector_cosine_ops")));

	if (!SvsClassifyDistanceMetric(opfamilyoid, inputTypeOid, &result))
	{
		Oid			distanceFuncOid = get_opfamily_proc(opfamilyoid, inputTypeOid,
														inputTypeOid, VAMANA_DISTANCE_PROC);
		char	   *funcName = get_func_name(distanceFuncOid);

		if (funcName == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("could not determine distance function name")));

		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("unsupported distance function for vamana index: %s", funcName),
				 errhint("Use vector_l2_ops, vector_ip_ops, or vector_cosine_ops")));
	}

	return result;
}

/*
 * Validator for a vamana opclass, modelled on gistvalidate
 * (access/gist/gistvalidate.c): GiST is the only core access method with
 * ordering-operator semantics like this one. Reports every problem found as
 * an INFO and returns false, rather than erroring, so that
 * SELECT oid, opcname FROM pg_opclass WHERE NOT amvalidate(oid) behaves the
 * way it does for every other access method.
 *
 * The type and metric checks reuse SvsClassifyIndexedType and
 * SvsClassifyDistanceMetric, the same helpers CREATE INDEX uses, so this
 * validator cannot accept an opclass shape that the build path would then
 * reject, or vice versa.
 */
bool
vamanavalidate(Oid opclassoid)
{
	bool		result = true;
	HeapTuple	classtup;
	Form_pg_opclass classform;
	Oid			opfamilyoid;
	Oid			opcintype;
	char	   *opclassname;
	char	   *opfamilyname;
	CatCList   *proclist;
	CatCList   *oprlist;
	List	   *grouplist;
	OpFamilyOpFuncGroup *opclassgroup;
	Oid			orderOpOid = InvalidOid;
	SVSDistanceType metric;
	bool		haveMetric;
	int			i;
	ListCell   *lc;

	classtup = SearchSysCache1(CLAOID, ObjectIdGetDatum(opclassoid));
	if (!HeapTupleIsValid(classtup))
		elog(ERROR, "cache lookup failed for operator class %u", opclassoid);
	classform = (Form_pg_opclass) GETSTRUCT(classtup);

	opfamilyoid = classform->opcfamily;
	opcintype = classform->opcintype;
	opclassname = NameStr(classform->opcname);

	opfamilyname = get_opfamily_name(opfamilyoid, false);

	oprlist = SearchSysCacheList1(AMOPSTRATEGY, ObjectIdGetDatum(opfamilyoid));
	proclist = SearchSysCacheList1(AMPROCNUM, ObjectIdGetDatum(opfamilyoid));

	/* Check 1: the indexed type must be one a vamana index can store. */
	if (SvsClassifyIndexedType(opcintype) == NULL)
	{
		ereport(INFO,
				(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
				 errmsg("operator family \"%s\" of access method %s does not support type %s",
						opfamilyname, "vamana", format_type_be(opcintype))));
		result = false;
	}
	else if (!SvsTypeIsFromVectorExtension(opcintype))
	{
		ereport(INFO,
				(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
				 errmsg("operator family \"%s\" of access method %s indexes type %s, which is not provided by the vector extension",
						opfamilyname, "vamana", format_type_be(opcintype))));
		result = false;
	}

	/* Check 2: every support function. */
	for (i = 0; i < proclist->n_members; i++)
	{
		HeapTuple	proctup = &proclist->members[i]->tuple;
		Form_pg_amproc procform = (Form_pg_amproc) GETSTRUCT(proctup);
		bool		ok;

		if (procform->amproclefttype != procform->amprocrighttype)
		{
			ereport(INFO,
					(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
					 errmsg("operator family \"%s\" of access method %s contains support function %s with different left and right input types",
							opfamilyname, "vamana",
							format_procedure(procform->amproc))));
			result = false;
		}

		/*
		 * As in gistvalidate, signatures can only be checked within the
		 * opclass's own type: a family may host groups for other type pairs
		 * (e.g. via ALTER OPERATOR FAMILY) that this opclass does not use.
		 */
		if (procform->amproclefttype != opcintype)
			continue;

		switch (procform->amprocnum)
		{
			case VAMANA_DISTANCE_PROC:
				ok = check_amproc_signature(procform->amproc, FLOAT8OID, true,
											2, 2, opcintype, opcintype);
				break;
			case VAMANA_NORM_PROC:
				ok = check_amproc_signature(procform->amproc, FLOAT8OID, true,
											1, 1, opcintype);
				break;
			case VAMANA_TYPE_INFO_PROC:
				ereport(INFO,
						(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
						 errmsg("operator family \"%s\" of access method %s contains function %s registered as support number %d, which access method %s does not use",
								opfamilyname, "vamana",
								format_procedure(procform->amproc),
								VAMANA_TYPE_INFO_PROC, "vamana")));
				result = false;
				continue;		/* don't want additional message */
			default:
				ereport(INFO,
						(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
						 errmsg("operator family \"%s\" of access method %s contains function %s with invalid support number %d",
								opfamilyname, "vamana",
								format_procedure(procform->amproc),
								procform->amprocnum)));
				result = false;
				continue;		/* don't want additional message */
		}

		if (!ok)
		{
			ereport(INFO,
					(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
					 errmsg("operator family \"%s\" of access method %s contains function %s with wrong signature for support number %d",
							opfamilyname, "vamana",
							format_procedure(procform->amproc),
							procform->amprocnum)));
			result = false;
		}
	}

	/* Check 3: every operator. */
	for (i = 0; i < oprlist->n_members; i++)
	{
		HeapTuple	oprtup = &oprlist->members[i]->tuple;
		Form_pg_amop oprform = (Form_pg_amop) GETSTRUCT(oprtup);

		if (oprform->amoppurpose != AMOP_ORDER)
		{
			ereport(INFO,
					(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
					 errmsg("operator family \"%s\" of access method %s contains search operator %s, but access method %s only supports ordering operators",
							opfamilyname, "vamana",
							format_operator(oprform->amopopr), "vamana")));
			result = false;
			continue;
		}

		if (oprform->amopstrategy != 1)
		{
			ereport(INFO,
					(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
					 errmsg("operator family \"%s\" of access method %s contains operator %s with invalid strategy number %d",
							opfamilyname, "vamana",
							format_operator(oprform->amopopr),
							oprform->amopstrategy)));
			result = false;
		}

		if (!opfamily_can_sort_type(oprform->amopsortfamily, get_op_rettype(oprform->amopopr)))
		{
			ereport(INFO,
					(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
					 errmsg("operator family \"%s\" of access method %s contains incorrect ORDER BY opfamily specification for operator %s",
							opfamilyname, "vamana",
							format_operator(oprform->amopopr))));
			result = false;
		}

		if (!check_amop_signature(oprform->amopopr, FLOAT8OID,
								  oprform->amoplefttype, oprform->amoprighttype))
		{
			ereport(INFO,
					(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
					 errmsg("operator family \"%s\" of access method %s contains operator %s with wrong signature",
							opfamilyname, "vamana",
							format_operator(oprform->amopopr))));
			result = false;
		}

		if (oprform->amopstrategy == 1 &&
			oprform->amoplefttype == opcintype &&
			oprform->amoprighttype == opcintype)
			orderOpOid = oprform->amopopr;
	}

	/* Check 4: completeness of the opclass's own (opcintype, opcintype) group. */
	grouplist = identify_opfamily_groups(oprlist, proclist);
	opclassgroup = NULL;
	foreach(lc, grouplist)
	{
		OpFamilyOpFuncGroup *thisgroup = (OpFamilyOpFuncGroup *) lfirst(lc);

		if (thisgroup->lefttype == opcintype && thisgroup->righttype == opcintype)
			opclassgroup = thisgroup;
	}

	if (!opclassgroup ||
		(opclassgroup->functionset & (((uint64) 1) << VAMANA_DISTANCE_PROC)) == 0)
	{
		ereport(INFO,
				(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
				 errmsg("operator class \"%s\" of access method %s is missing support function %d",
						opclassname, "vamana", VAMANA_DISTANCE_PROC)));
		result = false;
	}

	if (!opclassgroup ||
		(opclassgroup->operatorset & (((uint64) 1) << 1)) == 0)
	{
		ereport(INFO,
				(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
				 errmsg("operator class \"%s\" of access method %s is missing an ordering operator at strategy 1",
						opclassname, "vamana")));
		result = false;
	}

	/*
	 * Check 5: support function 1 must map to a metric the build path
	 * accepts, and support function 2 (norm) only makes sense paired with
	 * the inner-product/cosine metric.
	 */
	haveMetric = SvsClassifyDistanceMetric(opfamilyoid, opcintype, &metric);
	if (opclassgroup &&
		(opclassgroup->functionset & (((uint64) 1) << VAMANA_DISTANCE_PROC)) != 0 &&
		!haveMetric)
	{
		Oid			distanceFuncOid = get_opfamily_proc(opfamilyoid, opcintype,
														opcintype, VAMANA_DISTANCE_PROC);
		char	   *funcName = OidIsValid(distanceFuncOid) ? get_func_name(distanceFuncOid) : NULL;

		ereport(INFO,
				(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
				 errmsg("operator family \"%s\" of access method %s contains unsupported distance function%s%s",
						opfamilyname, "vamana",
						funcName ? " " : "", funcName ? funcName : "")));
		result = false;
	}

	if (haveMetric && metric == SVS_DISTANCE_L2 &&
		OidIsValid(get_opfamily_proc(opfamilyoid, opcintype, opcintype, VAMANA_NORM_PROC)))
	{
		ereport(INFO,
				(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
				 errmsg("operator family \"%s\" of access method %s has support function %d, but its distance metric is not inner-product or cosine",
						opfamilyname, "vamana", VAMANA_NORM_PROC)));
		result = false;
	}

	/*
	 * Check 7: the strategy-1 operator must actually implement the metric
	 * support function 1 maps to. This is the check that catches an
	 * opclass pairing (for example) <=> with an L2 support function 1: the
	 * build serves ORDER BY <=> from an L2 graph, with no recheck, which
	 * returns the wrong nearest neighbours rather than erroring. Name-based,
	 * like the rest of the metric mapping; that is a known property of this
	 * code, not something this check introduces.
	 */
	if (haveMetric && OidIsValid(orderOpOid))
	{
		Oid			orderFuncOid = get_opcode(orderOpOid);
		char	   *orderFuncName = OidIsValid(orderFuncOid) ? get_func_name(orderFuncOid) : NULL;
		bool		matches = false;

		if (orderFuncName != NULL)
		{
			switch (metric)
			{
				case SVS_DISTANCE_L2:
					matches = (strcmp(orderFuncName, "l2_distance") == 0);
					break;
				case SVS_DISTANCE_IP:
					matches = (strcmp(orderFuncName, "vector_negative_inner_product") == 0 ||
							   strcmp(orderFuncName, "halfvec_negative_inner_product") == 0);
					break;
				case SVS_DISTANCE_COSINE:
					matches = (strcmp(orderFuncName, "cosine_distance") == 0);
					break;
			}
		}

		if (!matches)
		{
			ereport(INFO,
					(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
					 errmsg("operator family \"%s\" of access method %s has an ordering operator %s that does not match its distance metric",
							opfamilyname, "vamana",
							format_operator(orderOpOid))));
			result = false;
		}
	}

	ReleaseCatCacheList(proclist);
	ReleaseCatCacheList(oprlist);
	ReleaseSysCache(classtup);

	return result;
}

/*
 * Reject vectors containing NaN or Inf before passing them to the SVS
 * library. SVS performs no input validation; non-finite values propagate
 * silently through distance computations (IEEE 754), corrupting k-NN
 * ranking without error. context is a short label used in the error
 * message ("insert", "build", "rebuild").
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
							i + 1, context)));
	}
}
