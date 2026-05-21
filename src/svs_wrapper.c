/*
 * svs_wrapper.c
 */

#include "postgres.h"
#include "svs_wrapper.h"
#include "vamana.h"
#include "miscadmin.h"
#include "utils/elog.h"

#include <unistd.h>

#ifdef USE_SVS
#include <svs/c_api/svs_c.h>
#endif

/* Returns nproc-1, minimum 1, reserving one CPU for the PG backend. */
static int
OnlineCpusMinus1(void)
{
	long		online_cpus = sysconf(_SC_NPROCESSORS_ONLN);

	return (online_cpus > 1) ? (int) (online_cpus - 1) : 1;
}

/*
 * Use max_parallel_maintenance_workers for build thread count.
 * Zero (default) falls back to nproc-1.  Non-zero is honored as-is;
 * DBAs may intentionally oversubscribe.
 */
int
SVSDefaultBuildThreads(void)
{
	int			workers = max_parallel_maintenance_workers;

	if (workers <= 0)
		return OnlineCpusMinus1();

	return workers;
}

/*
 * Use vamana.search_num_threads for search thread count.
 * Zero (default) falls back to nproc-1.  Not governed by
 * max_parallel_maintenance_workers, which is for maintenance only.
 */
int
SVSDefaultSearchThreads(void)
{
	if (vamana_search_num_threads > 0)
		return vamana_search_num_threads;

	return OnlineCpusMinus1();
}

#ifdef USE_SVS

typedef struct CompressionMapping
{
	int			param;
	svs_data_type_t svs_type;
}			CompressionMapping;

static const CompressionMapping compression_mappings[] = {
	{VAMANA_LEANVEC_UINT4, SVS_DATA_TYPE_UINT4},
	{VAMANA_LEANVEC_INT4, SVS_DATA_TYPE_INT4},
	{VAMANA_LEANVEC_UINT8, SVS_DATA_TYPE_UINT8},
	{VAMANA_LEANVEC_INT8, SVS_DATA_TYPE_INT8}
};

#define NUM_COMPRESSION_MAPPINGS (sizeof(compression_mappings) / sizeof(compression_mappings[0]))

static void
CheckSVSError(svs_error_h error, const char *operation)
{
	if (error && !svs_error_ok(error))
	{
		const char *msg = svs_error_get_message(error);
		svs_error_code_t code = svs_error_get_code(error);

		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("SVS %s failed: %s (code %d)",
						operation, msg ? msg : "unknown error", code)));
	}
}

/* param encoding: 4=UINT4, -4=INT4, 8=UINT8, -8=INT8 */
static svs_data_type_t
MapCompressionParamToSVSType(int param, const char *param_name)
{
	for (size_t i = 0; i < NUM_COMPRESSION_MAPPINGS; i++)
	{
		if (param == compression_mappings[i].param)
			return compression_mappings[i].svs_type;
	}

	ereport(ERROR,
			(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
			 errmsg("invalid %s value: %d", param_name, param),
			 errhint("Valid values are: %d (UINT4), %d (INT4), %d (UINT8), %d (INT8)",
					 VAMANA_LEANVEC_UINT4, VAMANA_LEANVEC_INT4,
					 VAMANA_LEANVEC_UINT8, VAMANA_LEANVEC_INT8)));

	return SVS_DATA_TYPE_VOID;	/* unreachable */
}
#endif

SVSAlgorithmHandle
SVSCreateAlgorithm(int graph_degree, int build_window, int search_window, int alpha,
				   bool use_search_history)
{
#ifdef USE_SVS
	svs_error_h error = svs_error_create();
	svs_algorithm_h algorithm;

	algorithm = svs_algorithm_create_vamana(
											(size_t) graph_degree,
											(size_t) build_window,
											(size_t) search_window,
											error);

	CheckSVSError(error, "algorithm creation");
	svs_error_free(error);

	if (alpha > 0)
	{
		svs_error_h alpha_error = svs_error_create();
		float		alpha_float = VAMANA_ALPHA_TO_FLOAT(alpha);

		svs_algorithm_vamana_set_alpha(algorithm, alpha_float, alpha_error);
		CheckSVSError(alpha_error, "setting alpha");
		svs_error_free(alpha_error);
	}

	{
		svs_error_h history_error = svs_error_create();

		svs_algorithm_vamana_set_use_search_history(algorithm, use_search_history, history_error);
		CheckSVSError(history_error, "setting use_search_history");
		svs_error_free(history_error);
	}

	return (SVSAlgorithmHandle) algorithm;
#else
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SVS library support not compiled in"),
			 errhint("Rebuild with SVS library support enabled.")));
	return NULL;
#endif
}

void
SVSFreeAlgorithm(SVSAlgorithmHandle algorithm)
{
#ifdef USE_SVS
	if (algorithm)
		svs_algorithm_free((svs_algorithm_h) algorithm);
#endif
}

SVSStorageHandle
SVSCreateSimpleStorage(SVSDType data_type)
{
#ifdef USE_SVS
	svs_error_h error = svs_error_create();
	svs_storage_h storage;
	svs_data_type_t svs_dtype;

	switch (data_type)
	{
		case SVS_DTYPE_FLOAT32:
			svs_dtype = SVS_DATA_TYPE_FLOAT32;
			break;
		case SVS_DTYPE_FLOAT16:
			svs_dtype = SVS_DATA_TYPE_FLOAT16;
			break;
		case SVS_DTYPE_INT8:
			svs_dtype = SVS_DATA_TYPE_INT8;
			break;
		case SVS_DTYPE_UINT8:
			svs_dtype = SVS_DATA_TYPE_UINT8;
			break;
		default:
			svs_error_free(error);
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("unsupported data type")));
			return NULL;
	}

	storage = svs_storage_create_simple(svs_dtype, error);

	CheckSVSError(error, "storage creation");
	svs_error_free(error);

	return (SVSStorageHandle) storage;
#else
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SVS library support not compiled in")));
	return NULL;
#endif
}

SVSStorageHandle
SVSCreateLeanVecStorage(int dimensions, int leanvec_dims, int primary_param, int secondary_param)
{
#ifdef USE_SVS
	svs_error_h error = svs_error_create();
	svs_storage_h storage;
	svs_data_type_t svs_primary;
	svs_data_type_t svs_secondary;
	size_t		actual_leanvec_dims;

	if (leanvec_dims <= 0)
		actual_leanvec_dims = (size_t) dimensions / VAMANA_LEANVEC_DEFAULT_DIM_DIVISOR;
	else
		actual_leanvec_dims = (size_t) leanvec_dims;

	if (actual_leanvec_dims == 0)
		actual_leanvec_dims = 1;	/* Minimum 1 dimension */

	svs_primary = MapCompressionParamToSVSType(primary_param, "compression_primary");
	svs_secondary = MapCompressionParamToSVSType(secondary_param, "compression_secondary");

	storage = svs_storage_create_leanvec(actual_leanvec_dims, svs_primary, svs_secondary, error);

	CheckSVSError(error, "LeanVec storage creation");
	svs_error_free(error);

	return (SVSStorageHandle) storage;
#else
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SVS library support not compiled in")));
	return NULL;
#endif
}

void
SVSFreeStorage(SVSStorageHandle storage)
{
#ifdef USE_SVS
	if (storage)
		svs_storage_free((svs_storage_h) storage);
#endif
}

SVSBuilderHandle
SVSCreateBuilder(SVSDistanceType metric, int dimensions, SVSAlgorithmHandle algorithm)
{
#ifdef USE_SVS
	svs_error_h error = svs_error_create();
	svs_index_builder_h builder;
	svs_distance_metric_t svs_metric;

	switch (metric)
	{
		case SVS_DISTANCE_L2:
			svs_metric = SVS_DISTANCE_METRIC_EUCLIDEAN;
			break;
		case SVS_DISTANCE_IP:
			svs_metric = SVS_DISTANCE_METRIC_DOT_PRODUCT;
			break;
		case SVS_DISTANCE_COSINE:
			svs_metric = SVS_DISTANCE_METRIC_COSINE;
			break;
		default:
			svs_error_free(error);
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("unsupported distance metric")));
			return NULL;
	}

	builder = svs_index_builder_create(
									   svs_metric,
									   (size_t) dimensions,
									   (svs_algorithm_h) algorithm,
									   error);

	CheckSVSError(error, "index builder creation");
	svs_error_free(error);

	return (SVSBuilderHandle) builder;
#else
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SVS library support not compiled in")));
	return NULL;
#endif
}

void
SVSFreeBuilder(SVSBuilderHandle builder)
{
#ifdef USE_SVS
	if (builder)
		svs_index_builder_free((svs_index_builder_h) builder);
#endif
}

void
SVSBuilderSetStorage(SVSBuilderHandle builder, SVSStorageHandle storage)
{
#ifdef USE_SVS
	svs_error_h error = svs_error_create();

	svs_index_builder_set_storage(
								  (svs_index_builder_h) builder,
								  (svs_storage_h) storage,
								  error);

	CheckSVSError(error, "setting storage on builder");
	svs_error_free(error);
#else
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SVS library support not compiled in")));
#endif
}

/*
 * SVS defaults to hardware_concurrency() threads, which can be hundreds on
 * large servers.  Pass SVSDefaultBuildThreads() to honour the
 * max_parallel_maintenance_workers GUC.
 */
void
SVSBuilderSetThreadpool(SVSBuilderHandle builder, int num_threads)
{
#ifdef USE_SVS
	svs_error_h error = svs_error_create();

	svs_index_builder_set_threadpool(
									 (svs_index_builder_h) builder,
									 SVS_THREADPOOL_KIND_NATIVE,
									 (size_t) num_threads,
									 error);

	CheckSVSError(error, "setting thread pool on builder");
	svs_error_free(error);
#else
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SVS library support not compiled in")));
#endif
}

void
SVSFreeIndex(SVSIndexHandle index)
{
#ifdef USE_SVS
	if (index)
		svs_index_free((svs_index_h) index);
#endif
}

int
SVSSearch(Oid indexRelid, SVSIndexHandle index, const float *query, int dimensions, int k,
		  int search_window_size, ItemPointer results, float *distances)
{
#ifdef USE_SVS
	svs_error_h error = svs_error_create();
	svs_search_results_t search_results;
	svs_search_params_h search_params;
	int			num_results;
	VamanaIndexCache *cachedIndex;

	cachedIndex = VamanaGetCache(indexRelid);

	if (!cachedIndex || !cachedIndex->isValid)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("SVS index not properly cached before search")));
	}

	if (!cachedIndex->tidMapping)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("TID mapping not found in cached index"),
				 errhint("Index may need to be rebuilt")));
	}

	search_params = svs_search_params_create_vamana((size_t) search_window_size, error);

	if (!svs_error_ok(error) || search_params == NULL)
	{
		CheckSVSError(error, "create search params");
		svs_error_free(error);
		return -1;
	}

	/* PG_FINALLY ensures search_params is freed even if search throws */
	PG_TRY();
	{
		search_results = svs_index_search(
										  (svs_index_h) index,
										  query,
										  1,	/* num_queries */
										  (size_t) k,
										  search_params,
										  error);
	}
	PG_FINALLY();
	{
		svs_search_params_free(search_params);
	}
	PG_END_TRY();

	if (!svs_error_ok(error) || search_results == NULL)
	{
		CheckSVSError(error, "search");
		svs_error_free(error);
		return 0;
	}
	svs_error_free(error);

	num_results = (search_results->num_queries > 0) ?
		(int) search_results->results_per_query[0] : 0;

	/* Limit results to actual number of vectors in index to avoid duplicates */
	if (num_results > cachedIndex->numVectors)
		num_results = cachedIndex->numVectors;

	{
		int			out = 0;	/* write index into results/distances */

		for (int i = 0; i < num_results && out < k; i++)
		{
			size_t		vector_index = search_results->indices[i];

			/*
			 * Bounds check against mapping capacity (may exceed numVectors
			 * after deletes)
			 */
			if (vector_index >= (size_t) cachedIndex->tidMappingCapacity)
			{
				ereport(ERROR,
						(errcode(ERRCODE_INTERNAL_ERROR),
						 errmsg("SVS returned invalid vector index %zu (capacity %d)",
								vector_index, cachedIndex->tidMappingCapacity)));
			}

			/*
			 * Skip soft-deleted entries (tidMapping slot is
			 * InvalidItemPointer)
			 */
			if (!ItemPointerIsValid(&cachedIndex->tidMapping[vector_index]))
				continue;

			ItemPointerCopy(&cachedIndex->tidMapping[vector_index], &results[out]);

			if (search_results->distances)
				distances[out] = search_results->distances[i];
			out++;
		}
		num_results = out;
	}

	svs_search_results_free(search_results);

	return num_results;
#else
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SVS library support not compiled in")));
	return 0;
#endif
}

/*
 * Batch search: numQueries row-major query vectors; results/distances are
 * row-major output arrays of numQueries*k entries.
 * numResultsPerQuery (optional): filled with per-query result count.
 * Returns total result count on success, -1 on error.
 */
int
SVSBatchSearch(Oid indexRelid, SVSIndexHandle index,
			   const float *queryData, int numQueries,
			   int dimensions, int k, int search_window_size,
			   ItemPointer results, float *distances,
			   int *numResultsPerQuery)
{
#ifdef USE_SVS
	svs_error_h error;
	svs_search_results_t search_results;
	svs_search_params_h search_params;
	VamanaIndexCache *cachedIndex;
	int			total = 0;

	if (numQueries <= 0)
		return 0;

	cachedIndex = VamanaGetCache(indexRelid);

	if (!cachedIndex || !cachedIndex->isValid)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("SVS index not properly cached before batch search")));

	if (!cachedIndex->tidMapping)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("TID mapping not found in cached index"),
				 errhint("Index may need to be rebuilt")));

	error = svs_error_create();
	search_params = svs_search_params_create_vamana(
													(size_t) search_window_size, error);

	if (!svs_error_ok(error) || search_params == NULL)
	{
		CheckSVSError(error, "create search params");
		svs_error_free(error);
		return -1;
	}

	/* PG_FINALLY ensures search_params is freed even if search throws */
	PG_TRY();
	{
		search_results = svs_index_search(
										  (svs_index_h) index,
										  queryData,
										  (size_t) numQueries,
										  (size_t) k,
										  search_params,
										  error);
	}
	PG_FINALLY();
	{
		svs_search_params_free(search_params);
	}
	PG_END_TRY();

	if (!svs_error_ok(error) || search_results == NULL)
	{
		CheckSVSError(error, "batch search");
		svs_error_free(error);
		return -1;
	}
	svs_error_free(error);

	for (int q = 0; q < numQueries; q++)
	{
		int			nr;
		ItemPointer qresults = results + (size_t) q * k;
		float	   *qdists = distances + (size_t) q * k;

		nr = ((size_t) q < search_results->num_queries) ?
			(int) search_results->results_per_query[q] : 0;

		if (nr > cachedIndex->numVectors)
			nr = cachedIndex->numVectors;

		{
			int			out = 0;

			for (int j = 0; j < nr && out < k; j++)
			{
				/* indices array is row-major with stride k: indices[q*k + j] */
				size_t		vector_index = search_results->indices[(size_t) q * k + j];

				if (vector_index >= (size_t) cachedIndex->tidMappingCapacity)
					ereport(ERROR,
							(errcode(ERRCODE_INTERNAL_ERROR),
							 errmsg("SVS returned invalid vector index %zu (capacity %d)",
									vector_index, cachedIndex->tidMappingCapacity)));

				/* Skip soft-deleted entries */
				if (!ItemPointerIsValid(&cachedIndex->tidMapping[vector_index]))
					continue;

				ItemPointerCopy(&cachedIndex->tidMapping[vector_index], &qresults[out]);

				if (search_results->distances)
					qdists[out] = search_results->distances[(size_t) q * k + j];
				out++;
			}
			nr = out;
		}

		if (numResultsPerQuery)
			numResultsPerQuery[q] = nr;
		total += nr;
	}

	svs_search_results_free(search_results);
	return total;
#else
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SVS library support not compiled in")));
	return 0;
#endif
}

int
SVSSaveIndex(SVSIndexHandle index, const char *path)
{
#ifdef USE_SVS
	svs_error_h error = svs_error_create();
	bool		ok;

	ok = svs_index_save((svs_index_h) index, path, error);

	if (!ok || !svs_error_ok(error))
	{
		const char *msg = svs_error_get_message(error);

		svs_error_free(error);
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("failed to save SVS index to \"%s\": %s",
						path, msg ? msg : "unknown error")));
		return -1;				/* unreachable */
	}

	svs_error_free(error);
	return 0;
#else
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SVS library support not compiled in")));
	return -1;
#endif
}

SVSIndexHandle
SVSBuildDynamicIndex(SVSBuilderHandle builder, const float *data,
					 const size_t *ids, int num_vectors, int *error_code)
{
#ifdef USE_SVS
	svs_error_h error = svs_error_create();
	svs_index_h index;

	index = svs_index_build_dynamic(
									(svs_index_builder_h) builder,
									data,
									ids,
									(size_t) num_vectors,
									0,	/* blocksize_bytes: use SVS default */
									error);

	if (error_code)
		*error_code = svs_error_ok(error) ? 0 : (int) svs_error_get_code(error);

	if (!svs_error_ok(error) || index == NULL)
	{
		CheckSVSError(error, "dynamic index build");
		svs_error_free(error);
		return NULL;
	}

	svs_error_free(error);
	return (SVSIndexHandle) index;
#else
	if (error_code)
		*error_code = -1;
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SVS library support not compiled in")));
	return NULL;
#endif
}

SVSIndexHandle
SVSLoadDynamicIndex(const char *path, const SVSBuildConfig * config)
{
#ifdef USE_SVS
	SVSAlgorithmHandle algorithm;
	SVSBuilderHandle builder;
	SVSStorageHandle storage;
	svs_index_h loaded;
	svs_error_h error;
	int			build_window;

	if (config->build_window_size > 0)
		build_window = config->build_window_size;
	else if (config->search_window_size > 0)
		build_window = config->search_window_size;
	else
		build_window = VAMANA_BUILD_WINDOW_FROM_DEGREE(config->graph_degree);

	algorithm = SVSCreateAlgorithm(config->graph_degree,
								   build_window,
								   config->search_window_size,
								   config->alpha,
								   false);

	builder = SVSCreateBuilder(config->distance_type,
							   config->dimensions,
							   algorithm);

	if (config->compression_type == VAMANA_COMPRESSION_LEANVEC)
		storage = SVSCreateLeanVecStorage(config->dimensions, config->leanvec_dims,
										  config->compression_primary,
										  config->compression_secondary);
	else
		storage = SVSCreateSimpleStorage(config->data_type);

	SVSBuilderSetStorage(builder, storage);
	{
		int			search_threads = SVSDefaultSearchThreads();

		SVSBuilderSetThreadpool(builder, search_threads);
		ereport(DEBUG1,
				(errmsg("loading SVS index with %d search threads "
						"(vamana.search_num_threads=%d, max_parallel_maintenance_workers=%d)",
						search_threads, vamana_search_num_threads,
						max_parallel_maintenance_workers)));
	}

	error = svs_error_create();
	loaded = svs_index_load_dynamic((svs_index_builder_h) builder, path, 0, error);

	SVSFreeBuilder(builder);
	SVSFreeAlgorithm(algorithm);
	SVSFreeStorage(storage);

	if (loaded == NULL || !svs_error_ok(error))
	{
		const char *msg = svs_error_get_message(error);

		svs_error_free(error);
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("failed to load dynamic SVS index from \"%s\": %s",
						path, msg ? msg : "unknown error")));
		return NULL;
	}

	svs_error_free(error);
	return (SVSIndexHandle) loaded;
#else
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SVS library support not compiled in")));
	return NULL;
#endif
}

int
SVSAddPoints(SVSIndexHandle index, const float *points, const size_t *ids, int num_vectors)
{
#ifdef USE_SVS
	svs_error_h error = svs_error_create();
	size_t		added;

	added = svs_index_dynamic_add_points(
										 (svs_index_h) index,
										 points,
										 ids,
										 (size_t) num_vectors,
										 error);

	if (!svs_error_ok(error))
	{
		const char *msg = svs_error_get_message(error);

		svs_error_free(error);
		ereport(WARNING,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("SVS dynamic add points failed: %s",
						msg ? msg : "unknown error")));
		return -1;
	}

	svs_error_free(error);
	return (int) added;
#else
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SVS library support not compiled in")));
	return -1;
#endif
}

int
SVSDeletePoints(SVSIndexHandle index, const size_t *ids, int num_ids)
{
#ifdef USE_SVS
	svs_error_h error = svs_error_create();
	size_t		deleted;

	deleted = svs_index_dynamic_delete_points(
											  (svs_index_h) index,
											  ids,
											  (size_t) num_ids,
											  error);

	if (!svs_error_ok(error))
	{
		const char *msg = svs_error_get_message(error);

		svs_error_free(error);
		ereport(WARNING,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("SVS dynamic delete points failed: %s",
						msg ? msg : "unknown error")));
		return -1;
	}

	svs_error_free(error);
	return (int) deleted;
#else
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SVS library support not compiled in")));
	return -1;
#endif
}

bool
SVSConsolidate(SVSIndexHandle index)
{
#ifdef USE_SVS
	svs_error_h error = svs_error_create();
	bool		ok;

	ok = svs_index_dynamic_consolidate((svs_index_h) index, error);

	if (!ok || !svs_error_ok(error))
	{
		const char *msg = svs_error_get_message(error);

		svs_error_free(error);
		ereport(WARNING,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("SVS dynamic consolidate failed: %s",
						msg ? msg : "unknown error")));
		return false;
	}

	svs_error_free(error);
	return true;
#else
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SVS library support not compiled in")));
	return false;
#endif
}

bool
SVSCompact(SVSIndexHandle index, size_t batchsize)
{
#ifdef USE_SVS
	svs_error_h error = svs_error_create();
	bool		ok;

	ok = svs_index_dynamic_compact((svs_index_h) index, batchsize, error);

	if (!ok || !svs_error_ok(error))
	{
		const char *msg = svs_error_get_message(error);

		svs_error_free(error);
		ereport(WARNING,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("SVS dynamic compact failed: %s",
						msg ? msg : "unknown error")));
		return false;
	}

	svs_error_free(error);
	return true;
#else
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("SVS library support not compiled in")));
	return false;
#endif
}

bool
SVSHasId(SVSIndexHandle index, size_t id)
{
#ifdef USE_SVS
	svs_error_h error = svs_error_create();
	bool		has_id = false;
	bool		ok;

	ok = svs_index_dynamic_has_id((svs_index_h) index, id, &has_id, error);

	if (!ok || !svs_error_ok(error))
	{
		svs_error_free(error);
		return false;
	}

	svs_error_free(error);
	return has_id;
#else
	return false;
#endif
}
