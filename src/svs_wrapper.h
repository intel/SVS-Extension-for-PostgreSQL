#ifndef SVS_WRAPPER_H
#define SVS_WRAPPER_H

#include "postgres.h"
#include "access/htup.h"
#include "storage/itemptr.h"

typedef void *SVSIndexHandle;
typedef void *SVSAlgorithmHandle;
typedef void *SVSStorageHandle;
typedef void *SVSBuilderHandle;

typedef enum
{
	SVS_DISTANCE_L2,
	SVS_DISTANCE_IP,
	SVS_DISTANCE_COSINE
}			SVSDistanceType;

typedef enum
{
	SVS_DTYPE_FLOAT32,
	SVS_DTYPE_FLOAT16,
	SVS_DTYPE_INT8,
	SVS_DTYPE_UINT8,
	SVS_DTYPE_INT4,
	SVS_DTYPE_UINT4
}			SVSDType;

typedef struct SVSBuildConfig 
{
	int			graph_degree;
	int			alpha;
	int			search_window_size;
	int			compression_type;		/* 0=none, 1=leanvec */
	int			compression_primary;	/* Primary quantization type */
	int			compression_secondary;	/* Secondary quantization type */
	SVSDistanceType distance_type;
	SVSDType	data_type;
	int			dimensions;				/* Vector dimensionality (needed for LeanVec load) */
	int			leanvec_dims;			/* LeanVec reduced dims (-1 = dimensions/2) */
	int			build_window_size;		/* Build window size from reloptions (0 = use default) */
}			SVSBuildConfig;

SVSAlgorithmHandle SVSCreateAlgorithm(int graph_degree, int build_window, int search_window, int alpha,
									  bool use_search_history);
void		SVSFreeAlgorithm(SVSAlgorithmHandle algorithm);

SVSStorageHandle SVSCreateSimpleStorage(SVSDType data_type);
SVSStorageHandle SVSCreateLeanVecStorage(int dimensions, int leanvec_dims, int primary_param, int secondary_param);
void		SVSFreeStorage(SVSStorageHandle storage);

SVSBuilderHandle SVSCreateBuilder(SVSDistanceType metric, int dimensions, SVSAlgorithmHandle algorithm);
void		SVSFreeBuilder(SVSBuilderHandle builder);
void		SVSBuilderSetStorage(SVSBuilderHandle builder, SVSStorageHandle storage);
void		SVSBuilderSetThreadpool(SVSBuilderHandle builder, int num_threads);
int			SVSDefaultBuildThreads(void);
int			SVSDefaultSearchThreads(void);

void		SVSFreeIndex(SVSIndexHandle index);

int			SVSSearch(Oid indexRelid, SVSIndexHandle index, const float *query, int dimensions, int k, int search_window_size, ItemPointer results, float *distances);

/*
 * Batch search: numQueries row-major query vectors; results/distances are
 * row-major output arrays of numQueries*k entries.
 * numResultsPerQuery (optional): caller-allocated int[numQueries]; filled with
 *   the result count for each query.  Pass NULL if not needed.
 * Returns total results count on success, -1 on error.
 */
int			SVSBatchSearch(Oid indexRelid, SVSIndexHandle index,
						   const float *queryData, int numQueries,
						   int dimensions, int k, int search_window_size,
						   ItemPointer results, float *distances,
						   int *numResultsPerQuery);

int			SVSSaveIndex(SVSIndexHandle index, const char *path);

SVSIndexHandle SVSBuildDynamicIndex(SVSBuilderHandle builder, const float *data,
									const size_t *ids, int num_vectors, int *error_code);
SVSIndexHandle SVSLoadDynamicIndex(const char *path, const SVSBuildConfig *config);

int			SVSAddPoints(SVSIndexHandle index, const float *points, const size_t *ids, int num_vectors);
int			SVSDeletePoints(SVSIndexHandle index, const size_t *ids, int num_ids);
bool		SVSConsolidate(SVSIndexHandle index);
bool		SVSCompact(SVSIndexHandle index, size_t batchsize);
bool		SVSHasId(SVSIndexHandle index, size_t id);

#endif
