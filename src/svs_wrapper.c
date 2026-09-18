/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_wrapper.c
 */

#include "postgres.h"
#include "svs_wrapper.h"
#include "vamana.h"
#include "miscadmin.h"
#include "port/pg_bitutils.h"
#include "utils/elog.h"

#include <svs/c/svs_c.h>

/*
 * Use max_parallel_maintenance_workers for build thread count.
 * Zero or negative means serial (1 thread), matching core's own meaning of
 * max_parallel_maintenance_workers = 0.  Non-zero is honored as-is; DBAs
 * may intentionally oversubscribe.
 */
int
SVSDefaultBuildThreads(void)
{
	int			workers = max_parallel_maintenance_workers;

	if (workers <= 0)
		return 1;

	return workers;
}

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
		char	   *msg = pstrdup(svs_error_get_message(error)
								   ? svs_error_get_message(error) : "unknown error");
		svs_error_code_t code = svs_error_get_code(error);

		/* Every caller's own error-object cleanup is unreachable once this
		 * throws, so free it here before doing so. */
		svs_error_free(error);

		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("SVS operation failed: %s", operation),
				 errdetail_log("SVS error: %s (code %d).",
							   msg ? msg : "unknown error", code)));
	}
}

/*
 * param encoding: 4=UINT4, -4=INT4, 8=UINT8, -8=INT8.  allow_none additionally
 * accepts 0, mapping it to SVS_DATA_TYPE_VOID; pass it only for LVQ's residual,
 * the one parameter for which "absent" is a legal value.
 */
static svs_data_type_t
MapCompressionParamToSVSType(int param, const char *param_name, bool allow_none)
{
	if (allow_none && param == VAMANA_COMPRESSION_NO_RESIDUAL)
		return SVS_DATA_TYPE_VOID;

	for (size_t i = 0; i < NUM_COMPRESSION_MAPPINGS; i++)
	{
		if (param == compression_mappings[i].param)
			return compression_mappings[i].svs_type;
	}

	ereport(ERROR,
			(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
			 errmsg("invalid %s value: %d", param_name, param),
			 errhint("Valid values are: %d (UINT4), %d (INT4), %d (UINT8), %d (INT8)%s",
					 VAMANA_LEANVEC_UINT4, VAMANA_LEANVEC_INT4,
					 VAMANA_LEANVEC_UINT8, VAMANA_LEANVEC_INT8,
					 allow_none ? ", 0 (no residual)" : "")));

	return SVS_DATA_TYPE_VOID;	/* unreachable */
}

/*
 * Never freed: reuse across calls is the point, and one worker process
 * serves one database single-threaded, so there's no concurrent access.
 */
static svs_search_results_t svsWorkerSearchResults = SVS_INIT_SEARCH_RESULTS();

SVSAlgorithmHandle
SVSCreateAlgorithm(int graph_degree, int build_window, int search_window, int alpha,
				   bool use_search_history)
{
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
}

void
SVSFreeAlgorithm(SVSAlgorithmHandle algorithm)
{
	if (algorithm)
		svs_algorithm_free((svs_algorithm_h) algorithm);
}

SVSStorageHandle
SVSCreateSimpleStorage(SVSDType data_type)
{
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
}

SVSStorageHandle
SVSCreateLeanVecStorage(int dimensions, int leanvec_dims, int primary_param, int secondary_param)
{
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

	svs_primary = MapCompressionParamToSVSType(primary_param, "compression_primary", false);
	svs_secondary = MapCompressionParamToSVSType(secondary_param, "compression_secondary", false);

	storage = svs_storage_create_leanvec(actual_leanvec_dims, svs_primary, svs_secondary, error);

	CheckSVSError(error, "LeanVec storage creation");
	svs_error_free(error);

	return (SVSStorageHandle) storage;
}

/*
 * LVQ quantizes in the original vector space, so unlike LeanVec it takes no
 * reduced dimensionality.  residual_param may be VAMANA_COMPRESSION_NO_RESIDUAL,
 * which SVS reads as zero residual bits.
 */
SVSStorageHandle
SVSCreateLVQStorage(int primary_param, int residual_param)
{
	svs_error_h error = svs_error_create();
	svs_storage_h storage;
	svs_data_type_t svs_primary;
	svs_data_type_t svs_residual;

	svs_primary = MapCompressionParamToSVSType(primary_param, "compression_primary", false);
	svs_residual = MapCompressionParamToSVSType(residual_param, "compression_secondary", true);

	storage = svs_storage_create_lvq(svs_primary, svs_residual, error);

	CheckSVSError(error, "LVQ storage creation");
	svs_error_free(error);

	return (SVSStorageHandle) storage;
}

/*
 * Single place that turns a compression_type into an SVS storage spec.  Every
 * path that constructs or reloads an index goes through here, so a build and
 * the later load of its saved file cannot disagree about the storage layout --
 * which is what SVS requires, and what three separate copies of this branch did
 * not guarantee.
 */
SVSStorageHandle
SVSCreateStorageForCompression(int compression_type, SVSDType data_type,
							   int dimensions, int leanvec_dims,
							   int compression_primary, int compression_secondary)
{
	switch (compression_type)
	{
		case VAMANA_COMPRESSION_LEANVEC:
			return SVSCreateLeanVecStorage(dimensions, leanvec_dims,
										   compression_primary,
										   compression_secondary);
		case VAMANA_COMPRESSION_LVQ:
			return SVSCreateLVQStorage(compression_primary, compression_secondary);
		default:
			return SVSCreateSimpleStorage(data_type);
	}
}

void
SVSFreeStorage(SVSStorageHandle storage)
{
	if (storage)
		svs_storage_free((svs_storage_h) storage);
}

SVSBuilderHandle
SVSCreateBuilder(SVSDistanceType metric, int dimensions, SVSAlgorithmHandle algorithm)
{
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
}

void
SVSFreeBuilder(SVSBuilderHandle builder)
{
	if (builder)
		svs_index_builder_free((svs_index_builder_h) builder);
}

void
SVSBuilderSetStorage(SVSBuilderHandle builder, SVSStorageHandle storage)
{
	svs_error_h error = svs_error_create();

	svs_index_builder_set_storage(
								  (svs_index_builder_h) builder,
								  (svs_storage_h) storage,
								  error);

	CheckSVSError(error, "setting storage on builder");
	svs_error_free(error);
}

/*
 * SVS defaults to hardware_concurrency() threads, which can be hundreds on
 * large servers.  Pass SVSDefaultBuildThreads() to honour the
 * max_parallel_maintenance_workers GUC.
 */
void
SVSBuilderSetThreadpool(SVSBuilderHandle builder, int num_threads)
{
	svs_error_h error = svs_error_create();

	svs_index_builder_set_threadpool(
									 (svs_index_builder_h) builder,
									 SVS_THREADPOOL_KIND_NATIVE,
									 (size_t) num_threads,
									 error);

	CheckSVSError(error, "setting thread pool on builder");
	svs_error_free(error);
}

void
SVSSetIndexSearchThreads(SVSIndexHandle index, int num_threads)
{
	svs_error_h error = svs_error_create();

	svs_index_set_num_threads((svs_index_h) index, (size_t) num_threads, error);
	CheckSVSError(error, "setting search threads on index");
	svs_error_free(error);
}

void
SVSFreeIndex(SVSIndexHandle index)
{
	if (index)
		svs_index_free((svs_index_h) index);
}

int
SVSSearch(Oid indexRelid, SVSIndexHandle index, const float *query, int dimensions, int k,
		  int search_window_size, ItemPointer results, float *distances)
{
	svs_error_h error;
	svs_search_params_h search_params;
	bool		ok;
	const size_t *row_ids;
	const float *row_distances;
	size_t		num_results;
	int			out;
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

	error = svs_error_create();

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
		ok = svs_index_search_topk(
									(svs_index_h) index,
									query,
									1,	/* num_queries */
									(size_t) k,
									&svsWorkerSearchResults,
									search_params,
									NULL,	/* id_filter: no qual pushdown yet */
									error);
	}
	PG_FINALLY();
	{
		svs_search_params_free(search_params);
	}
	PG_END_TRY();

	if (!ok || !svs_error_ok(error))
	{
		CheckSVSError(error, "search");
		svs_error_free(error);
		return 0;
	}
	svs_error_free(error);

	svs_search_results_row(&svsWorkerSearchResults, 0, &row_ids, &row_distances, &num_results);

	/* Limit results to actual number of vectors in index to avoid duplicates */
	if (num_results > (size_t) cachedIndex->numVectors)
		num_results = (size_t) cachedIndex->numVectors;

	out = 0;
	for (size_t i = 0; i < num_results && out < k; i++)
	{
		size_t		vector_index = row_ids[i];

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

		if (row_distances)
			distances[out] = row_distances[i];
		out++;
	}

	return out;
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
	svs_error_h error;
	svs_search_params_h search_params;
	bool		ok;
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
		ok = svs_index_search_topk(
									(svs_index_h) index,
									queryData,
									(size_t) numQueries,
									(size_t) k,
									&svsWorkerSearchResults,
									search_params,
									NULL,	/* id_filter: no qual pushdown yet */
									error);
	}
	PG_FINALLY();
	{
		svs_search_params_free(search_params);
	}
	PG_END_TRY();

	if (!ok || !svs_error_ok(error))
	{
		CheckSVSError(error, "batch search");
		svs_error_free(error);
		return -1;
	}
	svs_error_free(error);

	for (int q = 0; q < numQueries; q++)
	{
		const size_t *row_ids;
		const float *row_distances;
		size_t		nr;
		ItemPointer qresults = results + (size_t) q * k;
		float	   *qdists = distances + (size_t) q * k;
		int			out = 0;

		svs_search_results_row(&svsWorkerSearchResults, (size_t) q,
								&row_ids, &row_distances, &nr);

		if (nr > (size_t) cachedIndex->numVectors)
			nr = (size_t) cachedIndex->numVectors;

		for (size_t j = 0; j < nr && out < k; j++)
		{
			size_t		vector_index = row_ids[j];

			if (vector_index >= (size_t) cachedIndex->tidMappingCapacity)
				ereport(ERROR,
						(errcode(ERRCODE_INTERNAL_ERROR),
						 errmsg("SVS returned invalid vector index %zu (capacity %d)",
								vector_index, cachedIndex->tidMappingCapacity)));

			/* Skip soft-deleted entries */
			if (!ItemPointerIsValid(&cachedIndex->tidMapping[vector_index]))
				continue;

			ItemPointerCopy(&cachedIndex->tidMapping[vector_index], &qresults[out]);

			if (row_distances)
				qdists[out] = row_distances[j];
			out++;
		}

		if (numResultsPerQuery)
			numResultsPerQuery[q] = out;
		total += out;
	}

	return total;
}

uint64
SVSGetIndexMemoryUsage(SVSIndexHandle index)
{
	svs_error_h error = svs_error_create();
	size_t		bytes = 0;

	svs_index_get_memory_usage((svs_index_h) index, &bytes, error);

	CheckSVSError(error, "get index memory usage");
	svs_error_free(error);

	return bytes;
}

void
SVSGetIndexMemoryBreakdown(SVSIndexHandle index, SVSMemoryBreakdown *out)
{
	svs_error_h error = svs_error_create();
	svs_memory_breakdown_t breakdown = SVS_INIT_MEMORY_BREAKDOWN();

	svs_index_get_memory_breakdown((svs_index_h) index, &breakdown, error);

	CheckSVSError(error, "get index memory breakdown");
	svs_error_free(error);

	out->graphBytes = breakdown.graph_bytes;
	out->dataBytes = breakdown.data_bytes;
	out->metadataBytes = breakdown.metadata_bytes;
}

/*
 * SVS turns blocksize_bytes into elements-per-block as blocksize_bytes /
 * (sizeof(T) * dimensions), where T is this builder's real storage element
 * -- compressed for a LeanVec/LVQ builder, not a float. No API exposes
 * sizeof(T) directly, so find it by bisection: estimate_memory_dynamic is
 * an O(1) query that fails exactly when blocksize_bytes can't hold one
 * element, so the smallest passing value is sizeof(T) * dimensions itself.
 */
static size_t
SVSFindMinViableBlockSizeBytes(svs_index_builder_h builder)
{
	size_t		lo = 0;
	size_t		hi = 1;

	while (hi <= ((size_t) 1 << 48))
	{
		svs_error_h error = svs_error_create();
		svs_memory_breakdown_t breakdown = SVS_INIT_MEMORY_BREAKDOWN();
		bool		fits;

		svs_index_builder_estimate_memory_dynamic(builder, 1, hi, &breakdown, error);
		fits = svs_error_ok(error);
		svs_error_free(error);

		if (fits)
			break;

		lo = hi;
		hi <<= 1;
	}

	if (hi > ((size_t) 1 << 48))
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("could not determine this index's per-vector storage size")));

	while (hi - lo > 1)
	{
		size_t		mid = lo + (hi - lo) / 2;
		svs_error_h error = svs_error_create();
		svs_memory_breakdown_t breakdown = SVS_INIT_MEMORY_BREAKDOWN();
		bool		fits;

		svs_index_builder_estimate_memory_dynamic(builder, 1, mid, &breakdown, error);
		fits = svs_error_ok(error);
		svs_error_free(error);

		if (fits)
			hi = mid;
		else
			lo = mid;
	}

	return hi;
}

/*
 * SVS sizes a dynamic index in blocks; blocksize_bytes sets how many bytes
 * each block covers. SVS's own default is a fixed 1 GiB regardless of how
 * many vectors are involved, so a small index reports a footprint that has
 * nothing to do with its actual data. Size the block to the data instead:
 * cap it at the data's own byte size, and cap that at SVS's own default so
 * this never asks for a bigger block than SVS would have chosen itself.
 * Both svs_index_build_dynamic and svs_index_load_dynamic take this same
 * parameter, so both call sites need this same computation to agree.
 */
static size_t
SVSComputeBlockSizeBytes(svs_index_builder_h builder, int numVectors)
{
	svs_error_h error = svs_error_create();
	size_t		defaultBlockSizeBytes = 0;
	size_t		vectorBytes = SVSFindMinViableBlockSizeBytes(builder);
	size_t		dataBytes = (size_t) numVectors * vectorBytes;

	svs_index_builder_get_default_blocksize_bytes(builder, &defaultBlockSizeBytes, error);
	CheckSVSError(error, "get default block size");
	svs_error_free(error);

	return pg_nextpower2_size_t(Max(vectorBytes, Min(dataBytes, defaultBlockSizeBytes)));
}

void
SVSEstimateBuildMemory(SVSBuilderHandle builder, int numVectors, SVSMemoryBreakdown *out)
{
	svs_error_h error = svs_error_create();
	svs_memory_breakdown_t breakdown = SVS_INIT_MEMORY_BREAKDOWN();
	size_t		blocksizeBytes = SVSComputeBlockSizeBytes((svs_index_builder_h) builder,
															numVectors);

	svs_index_builder_estimate_memory_dynamic((svs_index_builder_h) builder,
											   (size_t) numVectors,
											   blocksizeBytes,
											   &breakdown,
											   error);

	CheckSVSError(error, "estimate build memory");
	svs_error_free(error);

	out->graphBytes = breakdown.graph_bytes;
	out->dataBytes = breakdown.data_bytes;
	out->metadataBytes = breakdown.metadata_bytes;
}

uint64
SVSEstimateSearchMemory(SVSBuilderHandle builder, int searchWindowSize, int numQueries, int numNeighbors,
						 int numVectors)
{
	svs_error_h error = svs_error_create();
	svs_search_params_h search_params;
	size_t		bytes = 0;

	search_params = svs_search_params_create_vamana((size_t) searchWindowSize, error);
	CheckSVSError(error, "create search params for search memory estimate");
	svs_error_free(error);

	if (search_params == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("SVS reported success but returned no search parameters")));

	PG_TRY();
	{
		/* SVS currently ignores blocksize_bytes here (SVS_UNUSED in index_builder.hpp); computed anyway for consistency. */
		size_t		blocksizeBytes = SVSComputeBlockSizeBytes((svs_index_builder_h) builder,
																numVectors);

		error = svs_error_create();

		svs_index_builder_estimate_search_memory_dynamic((svs_index_builder_h) builder,
														   (size_t) numQueries,
														   (size_t) numNeighbors,
														   search_params,
														   NULL, /* id_filter: no qual pushdown */
														   blocksizeBytes,
														   &bytes,
														   error);
	}
	PG_FINALLY();
	{
		svs_search_params_free(search_params);
	}
	PG_END_TRY();

	CheckSVSError(error, "estimate search memory");
	svs_error_free(error);

	return bytes;
}

int
SVSSaveIndex(SVSIndexHandle index, const char *path)
{
	svs_error_h error = svs_error_create();
	bool		ok;

	ok = svs_index_save((svs_index_h) index, path, error);

	if (!ok || !svs_error_ok(error))
	{
		const char *msg = svs_error_get_message(error);
		char	   *saved = pstrdup(msg ? msg : "unknown error");

		svs_error_free(error);
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("failed to save SVS index"),
				 errdetail_log("Path: \"%s\". SVS error: %s.", path, saved)));
		return -1;				/* unreachable */
	}

	svs_error_free(error);
	return 0;
}

SVSIndexHandle
SVSBuildDynamicIndex(SVSBuilderHandle builder, const float *data,
					 const size_t *ids, int num_vectors, int graph_degree,
					 int dimensions, int *error_code)
{
	svs_error_h error = svs_error_create();
	svs_index_h index;

	/*
	 * A block sized for the literal vector count would collapse to a
	 * single-element block on an empty-table's first insert (num_vectors ==
	 * 1), forcing SVS to allocate a new block on almost every subsequent add
	 * until this index is next loaded from disk with its real count. Floor
	 * the sizing input at graph_degree so a block holds at least one full
	 * neighbor list's worth of vectors.
	 */
	size_t		blocksizeBytes = SVSComputeBlockSizeBytes((svs_index_builder_h) builder,
															Max(num_vectors, graph_degree));

	index = svs_index_build_dynamic(
									(svs_index_builder_h) builder,
									data,
									ids,
									(size_t) num_vectors,
									blocksizeBytes,
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
}

SVSIndexHandle
SVSLoadDynamicIndex(const char *path, const SVSBuildConfig * config)
{
	SVSAlgorithmHandle algorithm = NULL;
	SVSBuilderHandle builder = NULL;
	SVSStorageHandle storage = NULL;
	svs_index_h loaded;
	svs_error_h error;
	int			build_window;

	build_window = (config->build_window_size > 0) ?
		config->build_window_size :
		VAMANA_BUILD_WINDOW_FROM_DEGREE(config->graph_degree);

	PG_TRY();
	{
		algorithm = SVSCreateAlgorithm(config->graph_degree,
									   build_window,
									   config->search_window_size,
									   config->alpha,
									   false);

		builder = SVSCreateBuilder(config->distance_type,
								   config->dimensions,
								   algorithm);

		storage = SVSCreateStorageForCompression(config->compression_type,
												config->data_type,
												config->dimensions,
												config->leanvec_dims,
												config->compression_primary,
												config->compression_secondary);

		SVSBuilderSetStorage(builder, storage);
		{
			SVSBuilderSetThreadpool(builder, config->search_num_threads);
			ereport(DEBUG1,
					(errmsg("loading SVS index with %d search threads",
							config->search_num_threads)));
		}

		{
			/* Same floor as SVSBuildDynamicIndex; see its comment. */
			size_t		blocksizeBytes = SVSComputeBlockSizeBytes((svs_index_builder_h) builder,
																	Max(config->numVectors, config->graph_degree));

			error = svs_error_create();
			loaded = svs_index_load_dynamic((svs_index_builder_h) builder, path, blocksizeBytes, error);
		}

		SVSFreeBuilder(builder);
		builder = NULL;
		SVSFreeAlgorithm(algorithm);
		algorithm = NULL;
		SVSFreeStorage(storage);
		storage = NULL;
	}
	PG_CATCH();
	{
		SVSFreeBuilder(builder);
		SVSFreeAlgorithm(algorithm);
		SVSFreeStorage(storage);
		PG_RE_THROW();
	}
	PG_END_TRY();

	if (loaded == NULL || !svs_error_ok(error))
	{
		const char *msg = svs_error_get_message(error);

		svs_error_free(error);
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("failed to load SVS index"),
				 errdetail_log("Path: \"%s\". SVS error: %s.",
							   path, msg ? msg : "unknown error")));
		return NULL;
	}

	svs_error_free(error);
	return (SVSIndexHandle) loaded;
}

int
SVSAddPoints(SVSIndexHandle index, const float *points, const size_t *ids, int num_vectors)
{
	svs_error_h error = svs_error_create();
	size_t		added = 0;
	bool		ok;

	ok = svs_index_dynamic_add_points(
									  (svs_index_h) index,
									  points,
									  ids,
									  (size_t) num_vectors,
									  &added,
									  error);

	if (!ok || !svs_error_ok(error))
	{
		const char *msg = svs_error_get_message(error);

		svs_error_free(error);
		ereport(WARNING,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("SVS dynamic add points failed"),
				 errdetail_log("SVS error: %s.", msg ? msg : "unknown error")));
		return -1;
	}

	svs_error_free(error);
	return (int) added;
}

int
SVSDeletePoints(SVSIndexHandle index, const size_t *ids, int num_ids)
{
	svs_error_h error = svs_error_create();
	size_t		deleted = 0;
	bool		ok;

	ok = svs_index_dynamic_delete_points(
										 (svs_index_h) index,
										 ids,
										 (size_t) num_ids,
										 &deleted,
										 error);

	if (!ok || !svs_error_ok(error))
	{
		const char *msg = svs_error_get_message(error);

		svs_error_free(error);
		ereport(WARNING,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("SVS dynamic delete points failed"),
				 errdetail_log("SVS error: %s.", msg ? msg : "unknown error")));
		return -1;
	}

	svs_error_free(error);
	return (int) deleted;
}

bool
SVSConsolidate(SVSIndexHandle index)
{
	svs_error_h error = svs_error_create();
	bool		ok;

	ok = svs_index_dynamic_consolidate((svs_index_h) index, error);

	if (!ok || !svs_error_ok(error))
	{
		const char *msg = svs_error_get_message(error);

		svs_error_free(error);
		ereport(WARNING,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("SVS dynamic consolidate failed"),
				 errdetail_log("SVS error: %s.", msg ? msg : "unknown error")));
		return false;
	}

	svs_error_free(error);
	return true;
}

bool
SVSCompact(SVSIndexHandle index, size_t batchsize)
{
	svs_error_h error = svs_error_create();
	bool		ok;

	ok = svs_index_dynamic_compact((svs_index_h) index, batchsize, error);

	if (!ok || !svs_error_ok(error))
	{
		const char *msg = svs_error_get_message(error);

		svs_error_free(error);
		ereport(WARNING,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("SVS dynamic compact failed"),
				 errdetail_log("SVS error: %s.", msg ? msg : "unknown error")));
		return false;
	}

	svs_error_free(error);
	return true;
}

bool
SVSHasId(SVSIndexHandle index, size_t id)
{
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
}
