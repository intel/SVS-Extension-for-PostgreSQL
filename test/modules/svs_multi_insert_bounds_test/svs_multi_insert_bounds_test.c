#include "postgres.h"
#include "vamana.h"
#include "vamana_replication.h"
#include "vamana_subxact_guard.h"
#include "vamana_subxid_pending_array.h"
#include "vamanaworker.h"
#include "svs_wrapper.h"
#include "fmgr.h"

PG_MODULE_MAGIC;

/*
 * Everything below is linked in only because it lives in the same
 * translation unit (vamana_replication.c) as VamanaMultiInsertCountsValid;
 * none of it is reachable from that pure predicate. Stubs match the no-op
 * pattern established by test/modules/svs_cache_load_test.c.
 */
VamanaWorkerShmem *VamanaWorkerShmemPtr = NULL;
bool vamana_eviction_suppressed = false;

bool
VamanaShutdownCancelPending(void)
{
	return false;
}

bool
VamanaWorkerIsAvailable(void)
{
	return false;
}

bool
VamanaWorkerRequestSlotDrop(Oid dbOid, Oid indexRelid)
{
	return false;
}

void
VamanaWorkerSignalReload(Oid indexRelid)
{
}

VamanaIndexCache *
VamanaGetCache(Oid indexRelid)
{
	return NULL;
}

void
VamanaForceHeapRebuild(Oid indexRelid)
{
}

float *
VamanaDatumToFloats(const VamanaTypeInfo *typeInfo, Datum datum, int *dim, const char *context)
{
	return NULL;
}

int
SVSAddPoints(SVSIndexHandle index, const float *points, const size_t *ids, int num_vectors)
{
	return 0;
}

int
SVSDeletePoints(SVSIndexHandle index, const size_t *ids, int num_ids)
{
	return 0;
}

VamanaSubXactResult
VamanaRunInSubXact(VamanaSubXactBody body, void *arg, VamanaSubXactShouldPropagate shouldPropagate)
{
	VamanaSubXactResult result = {0};

	return result;
}

VamanaSubxidPendingArray *
VamanaSubxidPendingArrayCreate(MemoryContext memContext, size_t elemSize,
							   size_t subxidOffset, int initialCapacity)
{
	return NULL;
}

void *
VamanaSubxidPendingArrayAppend(VamanaSubxidPendingArray *array)
{
	return NULL;
}

bool
VamanaSubxidPendingArrayHasLiveEntries(const VamanaSubxidPendingArray *array)
{
	return false;
}

void
VamanaSubxidPendingArrayPruneAbortedSubxact(VamanaSubxidPendingArray *array, SubTransactionId mySubid)
{
}

void
VamanaSubxidPendingArrayReparentSubxact(VamanaSubxidPendingArray *array,
										SubTransactionId mySubid, SubTransactionId parentSubid)
{
}

PG_FUNCTION_INFO_V1(svs_multi_insert_bounds_test_validate);
Datum
svs_multi_insert_bounds_test_validate(PG_FUNCTION_ARGS)
{
	int32 ntuples = PG_GETARG_INT32(0);
	bool isinit = PG_GETARG_BOOL(1);
	int64 dataLen = PG_GETARG_INT64(2);

	PG_RETURN_BOOL(VamanaMultiInsertCountsValid((uint16) ntuples, isinit, (Size) dataLen));
}
