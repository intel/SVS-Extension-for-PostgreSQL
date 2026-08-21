/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef VAMANA_H
#define VAMANA_H

#include "postgres.h"

#include "access/genam.h"
#include "access/xlogdefs.h"
#include "utils/hsearch.h"
#include "nodes/execnodes.h"
#include "nodes/pathnodes.h"
#include "optimizer/optimizer.h"
#include "utils/sampling.h"
#include "utils/timestamp.h"
#include "vector.h"
#include "svs_wrapper.h"

#define VAMANA_MAX_DIM 2000

/*
 * Maximum number of SVS index handles cached per process (background worker).
 */
#define VAMANA_MAX_CACHED_INDEXES 8

/* Support functions */
#define VAMANA_DISTANCE_PROC 1
#define VAMANA_NORM_PROC 2
#define VAMANA_TYPE_INFO_PROC 3

#define VAMANA_MAGIC_NUMBER 0xA954A954
#define VAMANA_PAGE_ID	0xFF91

/* Preserved page numbers */
#define VAMANA_METAPAGE_BLKNO	0
#define VAMANA_HEAD_BLKNO		1	/* first data page */

/* Vamana parameters */
#define VAMANA_DEFAULT_GRAPH_DEGREE		64
#define VAMANA_MIN_GRAPH_DEGREE			16
#define VAMANA_MAX_GRAPH_DEGREE			256
#define VAMANA_DEFAULT_ALPHA			-1  /* -1 = use SVS library default */
#define VAMANA_MIN_ALPHA				-1
#define VAMANA_MAX_ALPHA				200 /* 2.0 * 100 */
#define VAMANA_DEFAULT_BUILD_WINDOW		-1  /* -1 = 2 * graph_degree */
#define VAMANA_MIN_BUILD_WINDOW			-1
#define VAMANA_MAX_BUILD_WINDOW			1000
#define VAMANA_DEFAULT_SEARCH_WINDOW	100
#define VAMANA_MIN_SEARCH_WINDOW		10
#define VAMANA_MAX_SEARCH_WINDOW		10000
#define VAMANA_DEFAULT_USE_SEARCH_HISTORY	true

/* Compression types (internal representation) */
#define VAMANA_COMPRESSION_NONE			0
#define VAMANA_COMPRESSION_LEANVEC		1
#define VAMANA_COMPRESSION_LVQ			2
#define VAMANA_DEFAULT_COMPRESSION_TYPE	VAMANA_COMPRESSION_NONE

/* Compression type string values */
#define VAMANA_COMPRESSION_TYPE_NONE_STR		"none"
#define VAMANA_COMPRESSION_TYPE_LEANVEC_STR		"leanvec"
#define VAMANA_COMPRESSION_TYPE_LVQ_STR			"lvq"
#define VAMANA_DEFAULT_COMPRESSION_TYPE_STR		VAMANA_COMPRESSION_TYPE_NONE_STR

/* LeanVec compression data types (map to SVS data types) */
#define VAMANA_LEANVEC_UINT4			4
#define VAMANA_LEANVEC_INT4				-4
#define VAMANA_LEANVEC_UINT8			8
#define VAMANA_LEANVEC_INT8				-8

/* Centralized Vamana constants */
#define VAMANA_DEFAULT_BUILD_WINDOW_MULTIPLIER	2
#define VAMANA_BUILD_WINDOW_FROM_DEGREE(degree)	((degree) * VAMANA_DEFAULT_BUILD_WINDOW_MULTIPLIER)
#define VAMANA_ALPHA_SCALE						100.0
#define VAMANA_ALPHA_TO_FLOAT(a)				((float)(a) / VAMANA_ALPHA_SCALE)
#define VAMANA_INITIAL_BUFFER_CAPACITY			1000
#define VAMANA_PROGRESS_INTERVAL				100000	/* emit LOG every N tuples during long heap scans */
#define VAMANA_COST_SCALING_FACTOR				0.8		/* empirically tuned index cost multiplier */
#define VAMANA_LEANVEC_DEFAULT_DIM_DIVISOR		2

#define VAMANA_DEFAULT_LEANVEC_PRIMARY		VAMANA_LEANVEC_UINT8
#define VAMANA_DEFAULT_LEANVEC_SECONDARY	VAMANA_LEANVEC_UINT8
#define VAMANA_DEFAULT_LEANVEC_DIMS			-1	/* -1 = dimensions / 2 */
#define VAMANA_MIN_LEANVEC_DIMS				-1
#define VAMANA_MAX_LEANVEC_DIMS				2000

/* Build phases */
/* PROGRESS_CREATEIDX_SUBPHASE_INITIALIZE is 1 */
#define PROGRESS_VAMANA_PHASE_LOAD		2

/* Variables */
extern int	vamana_search_window_size;
extern int	vamana_search_num_threads;
extern int	vamana_compact_threshold_pct;
extern int	svs_max_search_threads_per_db;
extern int	svs_max_total_search_threads;

/* Checkpoint and replication slot GUCs */
extern int	vamana_checkpoint_debounce_window;
extern int	vamana_checkpoint_max_interval;
extern int	vamana_checkpoint_min_ops;
extern int	vamana_max_slot_wal_size_mb;
extern int	vamana_checkpoint_operations;
extern int	vamana_checkpoint_interval;
extern int	vamana_shutdown_drain_budget_ms;
extern int	vamana_worker_stop_timeout_ms;

/* Vamana index options */
typedef struct VamanaOptions 
{
	int32		vl_len_;		/* varlena header (do not touch directly!) */
	int			graph_degree;	/* R parameter (max degree) */
	int			alpha;			/* α for pruning (scaled by 100) */
	int			build_window_size;	/* Build window size (L parameter) */
	int			search_window_size;	/* Search window size for build and query */
	bool		use_search_history;	/* Maintain visited set during search */
	int			compression_type;	/* Compression type: 0=none, 1=leanvec, 2=lvq */
	int			compression_primary;	/* LeanVec primary quantization (4, 8, or negative for signed) */
	int			compression_secondary;	/* LeanVec secondary quantization */
	int			leanvec_dims;		/* LeanVec dimensions (-1 = dimensions/2) */
}			VamanaOptions;

typedef struct VamanaTypeInfo
{
	int			maxDimensions;
	Datum		(*normalize) (PG_FUNCTION_ARGS);
	void		(*checkValue) (Pointer v);
}			VamanaTypeInfo;

typedef struct VamanaSupport
{
	FmgrInfo   *procinfo;
	FmgrInfo   *normprocinfo;
	Oid			collation;
}			VamanaSupport;

typedef struct VamanaBuildState
{
	/* Info */
	Relation	heap;
	Relation	index;
	IndexInfo  *indexInfo;
	ForkNumber	forkNum;
	const		VamanaTypeInfo *typeInfo;

	/* Settings */
	int			dimensions;
	int			graph_degree;
	int			alpha;
	int			build_window_size;
	int			search_window_size;
	bool		use_search_history;
	int			compression_type;
	int			compression_primary;
	int			compression_secondary;
	int			leanvec_dims;
	SVSDistanceType	distance_type;	/* Distance metric for index */

	/* Statistics */
	double		indtuples;
	double		reltuples;

	/* Support functions */
	VamanaSupport support;

	/* Vector accumulation buffer (for batch build) */
	float	  **vectorBuffer;	/* Array of vector pointers */
	ItemPointerData *tidBuffer; /* Corresponding heap TIDs (array of structs) */
	int			numVectors;		/* Current count */
	int			bufferCapacity; /* Allocated capacity */

	/* Memory */
	MemoryContext buildCtx;
	MemoryContext tmpCtx;
}			VamanaBuildState;

typedef struct VamanaMetaPageData
{
	uint32		magicNumber;
	uint32		dimensions;
	uint16		graph_degree;
	uint16		alpha;
	uint8		compression_type;	/* 0=none, 1=leanvec */
	int8		compression_primary;	/* LeanVec primary (signed for type encoding) */
	int8		compression_secondary;	/* LeanVec secondary */
	BlockNumber indexDataBlkno; /* Start of SVS index data */
	Size		indexDataSize;	/* Size in bytes */
	uint32		numVectors;
	bool		hasSavedIndex;	/* true if a serialized copy exists on disk */
	uint64		nextExternalId; /* next ID to assign on insert (authoritative) */
	uint32		numDeleted;		/* soft-deleted entries not yet compacted */
	uint32		tidMappingCapacity; /* allocated slots in tidMapping (>= numVectors) */
}			VamanaMetaPageData;

typedef VamanaMetaPageData * VamanaMetaPage;

StaticAssertDecl(offsetof(VamanaMetaPageData, nextExternalId) == 40,
				 "VamanaMetaPageData.nextExternalId offset changed — on-disk compatibility broken");
StaticAssertDecl(offsetof(VamanaMetaPageData, numDeleted) == 48,
				 "VamanaMetaPageData.numDeleted offset changed — on-disk compatibility broken");
StaticAssertDecl(offsetof(VamanaMetaPageData, tidMappingCapacity) == 52,
				 "VamanaMetaPageData.tidMappingCapacity offset changed — on-disk compatibility broken");
StaticAssertDecl(sizeof(VamanaMetaPageData) == 56,
				 "VamanaMetaPageData size changed — update readers/writers");

typedef struct VamanaPageOpaqueData
{
	BlockNumber nextblkno;
	uint16		unused;
	uint16		page_id;		/* for identification of Vamana indexes */
}			VamanaPageOpaqueData;

typedef VamanaPageOpaqueData * VamanaPageOpaque;

/*
 * Full definition in vamana_replication.h.
 * VamanaIndexCache holds a pointer so this header stays free of replication
 * internals.
 */
struct VamanaReplicationSlot;

/* Background worker's per-process index cache (not shared memory) */
typedef struct VamanaIndexCache
{
	SVSIndexHandle svsIndex;	/* Cached SVS index */
	Oid			indexRelid;		/* Relation OID */
	bool		isValid;		/* Is cache valid? */
	int			dimensions;		/* Vector dimensions */
	int			graph_degree;	/* Graph degree parameter */
	float		alpha;			/* Alpha parameter */
	MemoryContext memCtx;		/* Memory context for cache */
	ItemPointerData *tidMapping; /* Maps external IDs to PostgreSQL TIDs */
	int			numVectors;		/* Live vector count (excludes soft-deleted) */
	bool		needsSave;		/* true after in-memory rebuild, cleared on save */
	int			tidMappingCapacity; /* allocated slots in tidMapping */
	uint64		nextExternalId; /* local mirror of metapage nextExternalId */
	int			numDeleted;		/* soft-deleted entries not yet compacted */

	/* Replication slot and WAL replay state */
	struct VamanaReplicationSlot *replicationSlot;
	XLogRecPtr	lastReplayLsn;
	XLogRecPtr	lastReplayWalEnd;
	Oid			heapRelid;			/* heap relation OID (for replay decoder) */
	int			vectorAttNum;		/* 0-based heap attribute number of the vector column */
	HTAB	   *tidToExternalId;	/* TID → externalId reverse lookup; NULL until first populate */

	/* Checkpoint debounce state */
	int64		opsSinceCheckpoint;
	TimestampTz lastWriteTime;		/* updated on every write slot; 0 = no writes yet */
	TimestampTz lastCheckpointTime;	/* 0 = treat as infinite elapsed */
	bool		checkpointInProgress;
}			VamanaIndexCache;

typedef struct VamanaScanOpaqueData
{
	const		VamanaTypeInfo *typeInfo;
	Oid			indexRelid;		/* Index relation OID for cache lookup */
	SVSIndexHandle svsIndex;	/* Cached SVS index */
	Datum		queryValue;
	int			k;
	int			searchWindowSize;

	/* Result management */
	ItemPointer results;
	float	   *distances;
	int			numResults;
	int			currentResult;

	/* Support functions */
	VamanaSupport support;
}			VamanaScanOpaqueData;

typedef VamanaScanOpaqueData * VamanaScanOpaque;

#define VamanaPageGetOpaque(page)	((VamanaPageOpaque) PageGetSpecialPointer(page))
#define VamanaPageGetMeta(page)		((VamanaMetaPageData *) PageGetContents(page))

/* Methods */
int			VamanaGetGraphDegree(Relation index);
int			VamanaGetAlpha(Relation index);
FmgrInfo   *VamanaOptionalProcInfo(Relation index, uint16 procnum);
void		VamanaInitSupport(VamanaSupport * support, Relation index);
Buffer		VamanaNewBuffer(Relation index, ForkNumber forkNum);
void		VamanaInitPage(Buffer buf, Page page);
void		VamanaInit(void);
const		VamanaTypeInfo *VamanaGetTypeInfo(Relation index);
void		VamanaGetMetaPageInfo(Relation index, int *graph_degree, int *dimensions);
void		VamanaReadMetaPage(Relation index, VamanaMetaPageData *meta);
void		VamanaUpdateMetaPage(Relation index, BlockNumber indexDataBlkno, Size indexDataSize, uint32 numVectors, ForkNumber forkNum);
void		VamanaSetHasSavedIndex(Relation index, bool hasSavedIndex, ForkNumber forkNum);
bytea	   *vamanaoptions(Datum reloptions, bool validate);
void		vamanacostestimate(PlannerInfo *root, IndexPath *path, double loop_count,
							   Cost *indexStartupCost, Cost *indexTotalCost,
							   Selectivity *indexSelectivity, double *indexCorrelation,
							   double *indexPages);
char	   *vamanabuildphasename(int64 phaseNum);
bool		vamanavalidate(Oid opclassoid);

/* Distance metric helper */
SVSDistanceType VamanaGetDistanceMetric(Relation index);

/* On-disk serialization helpers */
void		VamanaGetIndexSavePath(Oid dboid, Oid relid, char *buf, size_t bufsz);
void		VamanaEnsureSaveDir(Oid dboid, Oid relid);
void		VamanaDeleteSaveDir(Oid dboid, Oid relid);
void		VamanaSaveIndexToDisk(Relation index, SVSIndexHandle svsIndex, ForkNumber forkNum,
								  const VamanaIndexCache *meta);
bool		VamanaLoadTidMap(Oid dboid, Oid relid, ItemPointerData *tidMapping, int tidMappingCapacity);
void		VamanaSaveTidMapAtomically(Oid dboid, Oid relid, ItemPointerData *tidMapping, int count);
void		VamanaInstallObjectAccessHook(void);
void		VamanaValidateVectorData(const float *data, int dim, const char *context);

/* Dynamic index support */
void		VamanaWriteMetaPageDynamic(Relation index, uint64 nextExternalId,
									   uint32 numVectors, uint32 numDeleted,
									   uint32 tidMappingCapacity, ForkNumber forkNum);

/* Cache management */
void		VamanaCacheIndex(Oid indexRelid, SVSIndexHandle svsIndex, int dimensions,
							 int graph_degree, float alpha, ItemPointerData * tidMapping,
							 int numVectors, int tidMappingCapacity,
							 uint64 nextExternalId, int numDeleted);
SVSIndexHandle VamanaGetCachedIndex(Oid indexRelid, bool *needsRebuild);
VamanaIndexCache *VamanaGetCache(Oid indexRelid);
void		VamanaCacheForgetExternalId(VamanaIndexCache *cache, size_t externalId);
void		VamanaInvalidateCache(Oid indexRelid);
void		VamanaEvictCacheEntry(Oid indexRelid);
void		VamanaForceHeapRebuild(Oid indexRelid);
void		VamanaEvictAllCacheEntries(void);
int			VamanaGetAllCachedRelids(Oid *out, int maxout);
void		VamanaCacheSetNeedsSave(Oid indexRelid, bool flag);
bool		VamanaCacheGetNeedsSave(Oid indexRelid);
SVSIndexHandle VamanaRebuildFromTable(Relation index);

/*
 * Load a previously saved SVS index from disk.  Defined in vamanascan.c.
 * Returns the loaded handle on success, NULL if no saved copy exists or
 * loading fails (caller may then fall back to VamanaRebuildFromTable).
 */
SVSIndexHandle LoadIndexFromPages(Relation index);

/* Index access methods */
IndexBuildResult *vamanabuild(Relation heap, Relation index, IndexInfo *indexInfo);
void		vamanabuildempty(Relation index);
bool		vamanainsert(Relation index, Datum *values, bool *isnull, ItemPointer heap_tid, Relation heap, IndexUniqueCheck checkUnique
#if PG_VERSION_NUM >= 140000
						 ,bool indexUnchanged
#endif
						 ,IndexInfo *indexInfo
);
IndexBulkDeleteResult *vamanabulkdelete(IndexVacuumInfo *info, IndexBulkDeleteResult *stats, IndexBulkDeleteCallback callback, void *callback_state);
IndexBulkDeleteResult *vamanavacuumcleanup(IndexVacuumInfo *info, IndexBulkDeleteResult *stats);
IndexScanDesc vamanabeginscan(Relation index, int nkeys, int norderbys);
void		vamanarescan(IndexScanDesc scan, ScanKey keys, int nkeys, ScanKey orderbys, int norderbys);
bool		vamanagettuple(IndexScanDesc scan, ScanDirection dir);
void		vamanaendscan(IndexScanDesc scan);

#endif
