# Dynamic Vamana Index: Design Notes

## Table of Contents

1. [Architecture](#1-architecture)
2. [The Write Path in Detail](#2-the-write-path-in-detail)
3. [The Read Path and Soft-Delete Semantics](#3-the-read-path-and-soft-delete-semantics)
4. [Persistence and On-Disk Format](#4-persistence-and-on-disk-format)
5. [Performance](#5-performance)
6. [Known Limitations](#6-known-limitations)
7. [Reference: New and Changed Symbols](#7-reference-new-and-changed-symbols)

---

## 1. Architecture

### 1.1 Where dynamic behavior lives

```
┌───────────────────────────────────────────────────────────────┐
│ vamanabuild.c                                                 │
│   vamanabuild() ──► SVSBuildDynamicIndex()                    │
├───────────────────────────────────────────────────────────────┤
│ vamanainsert.c                                                │
│   vamanainsert()                                              │
│     └─ VamanaWorkerSubmitInsert (BGW: exclusive LWLock,       │
│         SVSAddPoints, update metapage)                        │
├───────────────────────────────────────────────────────────────┤
│ vamanavacuum.c                                                │
│   vamanabulkdelete()                                          │
│     ├─ walk tidMapping, collect dead IDs via PG callback      │
│     └─ VamanaWorkerSubmitDelete (BGW: exclusive LWLock,       │
│         SVSDeletePoints, update metapage)                     │
│   vamanavacuumcleanup()                                       │
│     ├─ VamanaWorkerSubmitMaintenance(CONSOLIDATE)             │
│     │   (always if numDeleted > 0)                            │
│     └─ VamanaWorkerSubmitMaintenance(COMPACT)                 │
│         (gated by svs.compact_threshold_pct)                  │
├───────────────────────────────────────────────────────────────┤
│ vamanautils.c                                                 │
│   VamanaRebuildFromTable() ──► SVSBuildDynamicIndex()         │
│   VamanaWriteMetaPageDynamic() (new)                          │
├───────────────────────────────────────────────────────────────┤
│ vamanascan.c                                                  │
│   LoadIndexFromPages()                                        │
│     └─ SVSLoadDynamicIndex on the saved directory             │
│   SVSSearch skips InvalidItemPointer slots (soft-delete)      │
└───────────────────────────────────────────────────────────────┘
```

### 1.2 Metapage layout

```c
/* src/vamana.h */
typedef struct VamanaMetaPageData
{
    uint32 magicNumber;
    uint32 dimensions;
    uint16 graph_degree;
    uint16 alpha;
    uint8  compression_type;
    int8   compression_primary;
    int8   compression_secondary;
    BlockNumber indexDataBlkno;
    Size   indexDataSize;
    uint32 numVectors;
    bool   hasSavedIndex;
    uint64 nextExternalId;         /* authoritative next SVS ID */
    uint32 numDeleted;             /* soft-deleted count not yet compacted */
    uint32 tidMappingCapacity;     /* allocated slots in TID map (>= numVectors) */
} VamanaMetaPageData;
```

**Why these fields.**

- `nextExternalId` — SVS external IDs must be unique *for the life of
  the index*. The metapage is the single source of truth across
  backends; the BGW reads it while holding the exclusive per-index
  LWLock, passes the value to `SVSAddPoints`, and writes `value+1` back.
- `numDeleted` — drives the `SVSCompact` decision threshold (see
  `svs.compact_threshold_pct`) and reports deletion pressure.
- `tidMappingCapacity` — after deletes, the TID mapping array has
  holes. `numVectors` tracks live entries; `tidMappingCapacity` tracks
  the allocated length (which is what the sidecar `tidmap.bin` file
  serializes). Search uses the capacity as its upper bound, then
  filters `InvalidItemPointer` slots.

### 1.3 In-memory cache (`VamanaIndexCache`)

The BGW's per-process cache mirrors the metapage and adds a few runtime
fields:

```c
/* src/vamana.h */
typedef struct VamanaIndexCache
{
    SVSIndexHandle svsIndex;
    Oid            indexRelid;
    bool           isValid;
    int            dimensions;
    int            graph_degree;
    float          alpha;
    MemoryContext  memCtx;
    ItemPointerData *tidMapping;
    int            numVectors;
    bool           needsSave;
    int            tidMappingCapacity;
    uint64         nextExternalId;  /* local mirror of the metapage value */
    int            numDeleted;
} VamanaIndexCache;
```

> **Important:** `cache->nextExternalId` is a mirror of the metapage, not
> authoritative. The BGW re-reads the metapage while holding the exclusive
> per-index LWLock before assigning an ID, ensuring monotonic assignment
> even if the cached value is stale.

---

## 2. The Write Path in Detail

### 2.1 INSERT

```
vamanainsert(index, values, isnull, heap_tid, ...)
  │
  ├─ VamanaWorkerWaitUntilAvailable(relid)      // error if BGW not up
  ├─ vec = PG_DETOAST_DATUM_COPY(values[0])     // aligned, standalone palloc
  ├─ VamanaWorkerSubmitInsert(relid, vec, heap_tid, &externalId)
  │   BGW side:
  │     ├─ LWLockAcquire(VamanaGetIndexLock(relid), LW_EXCLUSIVE)
  │     ├─ VamanaReadMetaPage → externalId
  │     ├─ SVSAddPoints(svsIndex, vec, &externalId, 1)
  │     ├─ tidMapping[externalId] = heap_tid
  │     ├─ cache->nextExternalId++, numVectors++, needsSave = true
  │     └─ VamanaWriteMetaPageDynamic(...)       // WAL-logged, single page
  │
  └─ VamanaUndoAppend(relid, externalId)        // for rollback on abort
```

Key invariants and observations:

- The lock is a per-index LWLock in shared memory, obtained via
  `VamanaGetIndexLock(relid)` (tranche `vamana_index_rwlock`). Its slot
  is keyed by relation OID in the `VamanaIndexLockSlot` array, so it is
  per-index. It is held for the duration of the BGW operation, not tied
  to transaction lifetime.
- Writers take the lock in `LW_EXCLUSIVE` mode; searches take it in
  `LW_SHARED` mode. Concurrent searches share the lock with each other,
  but an in-progress write excludes searches (and vice versa) on the
  same index for its duration.
- The metapage write goes through `GenericXLogFinish`, so the fields
  update atomically in one WAL record.
- `needsSave = true` defers serialization. The actual
  `VamanaSaveIndexToDisk` call runs from the BGW's maintenance loop,
  never from the insert hot path.

### 2.2 DELETE + VACUUM

`vamanabulkdelete` receives PostgreSQL's dead-tuple callback, collects
dead external IDs from the TID map, then submits batched DELETE requests
to the BGW:

```
vamanabulkdelete(info, stats, callback, state)
  │
  ├─ VamanaWorkerAssertDatabase() + VamanaWorkerIsAvailable() → ERROR if down
  │
  ├─ for i in 0 .. tidMappingCapacity-1:
  │     if callback(tip, state):                  // PG says this heap TID is dead
  │         deadIds[numDead++] = i
  │         ItemPointerSetInvalid(tip)            // mark slot immediately
  │
  └─ VamanaWorkerSubmitDelete(relid, deadIds, batch) [batched]
      BGW side: SVSDeletePoints + VamanaWriteMetaPageDynamic
```

`vamanavacuumcleanup` runs after `vamanabulkdelete` completes:

- `VamanaWorkerSubmitMaintenance(CONSOLIDATE)` is sent whenever
  `numDeleted > 0`. The BGW calls `SVSConsolidate` to patch graph edges
  that pointed at deleted entries. Recall of the remaining vectors is
  preserved.
- `VamanaWorkerSubmitMaintenance(COMPACT)` is sent **only** when
  `numDeleted / numVectors > svs.compact_threshold_pct / 100`
  (default 10%). The BGW calls `SVSCompact`, which physically reclaims
  slot memory while preserving external IDs.

### 2.3 Why the slot is marked invalid *before* SVS delete succeeds

The dead-TID marking block runs before the BGW delete is submitted:

```c
if (callback(tip, callback_state))
{
    deadIds[numDead++] = (size_t) i;
    /* Mark the slot invalid immediately so searches skip it. */
    ItemPointerSetInvalid(tip);
}
```

The `ItemPointerSetInvalid` call runs **before** `VamanaWorkerSubmitDelete`.
If the BGW delete then fails, the heap already reflects the deletion so
the next rebuild from the heap produces a correct index. Leaving the TID
valid in the interim would risk returning a dead row in a concurrent
SELECT that raced the delete path.

### 2.4 BGW cold-cache behaviour (INSERT)

`vamanainsert` calls `VamanaWorkerWaitUntilAvailable` before submitting.
If the BGW is up but has not yet loaded the index (e.g. immediately after
server restart), the BGW loads it on the first request via
`VamanaWorkerGetOrLoadIndex`: try `LoadIndexFromPages`, fall back to
`VamanaRebuildFromTable` if no saved copy exists. Subsequent inserts
find the index already in the BGW cache and take the fast path.

---

## 3. The Read Path and Soft-Delete Semantics

The search function `SVSSearch` is the query-time hot path.
Two changes affect reads under dynamic indexes:

### 3.1 Bounds check widened to `tidMappingCapacity`

Static indexes always had `numVectors == tidMappingCapacity`. Dynamic
indexes can have `tidMappingCapacity > numVectors` because deleted
slots stay allocated (as holes) until compaction. SVS may return
indices up to the full capacity, and the search loop now bounds-checks
against `cachedIndex->tidMappingCapacity` rather than `numVectors`:

```c
/* src/svs_wrapper.c */
if (vector_index >= (size_t) cachedIndex->tidMappingCapacity)
    ereport(ERROR, ...);
```

### 3.2 Soft-delete filtering

The search loop skips any slot whose TID is `InvalidItemPointer`:

```c
/* src/svs_wrapper.c */
if (!ItemPointerIsValid(&cachedIndex->tidMapping[vector_index]))
    continue;
```

This is the read-side half of the bulk-delete protocol in [§2.2](#22-delete--vacuum).
Between `VACUUM`'s write-lock release and the next `SVSConsolidate`,
SVS may still surface the deleted vectors as candidates; the filter
ensures they never reach the client.

### 3.3 `k` vs. `out`

Because the filter can drop results, the loop uses a separate `out`
counter rather than the raw SVS index `i`. The returned `num_results`
is the number of *surviving* results, which may be less than `k`. This
matches the existing pgvector contract for sparse result sets.

---

## 4. Persistence and On-Disk Format

Two artefacts are written per index:

1. **The SVS graph** — a directory at
   `$PGDATA/vamana_indexes/<oid>/` written by
   `svs_index_save`/`svs_index_save_dynamic` (the latter is invoked
   indirectly via `SVSSaveIndex` — the SVS C API auto-detects the
   dynamic handle).
2. **The TID map sidecar** — `tidmap.bin` in the same directory,
   `tidMappingCapacity × sizeof(ItemPointerData)` bytes. Written
   atomically via temp-file + rename (`VamanaSaveTidMapAtomically`).

The metapage `hasSavedIndex`, `indexDataBlkno`, `indexDataSize`,
`numVectors`, and all four v2 fields are flipped to their final values
in a single `GenericXLog` transaction after the files are durable
(the index-saved flag and all v2 fields are written atomically in a single WAL record after the files are durable).

### 4.1 Load path

```
LoadIndexFromPages(index)
  │
  ├─ VamanaReadMetaPage(&meta)
  ├─ if !meta.hasSavedIndex:                    return NULL (cold rebuild)
  ├─ if save dir missing:                       clear flag, return NULL
  │
  ├─ tidMappingCapacity = meta.tidMappingCapacity
  ├─ nextExternalId     = meta.nextExternalId
  ├─ numDeleted         = meta.numDeleted
  │
  ├─ config = reconstruct SVSBuildConfig from meta + reloptions
  │
  ├─ SVSLoadDynamicIndex(savepath, &config)
  │
  ├─ VamanaLoadTidMap(relid, tidMapping, tidMappingCapacity)
  │
  └─ VamanaCacheIndex(..., tidMappingCapacity, nextExternalId, numDeleted)
```

### 4.2 Save path

Saves (checkpoints) are performed exclusively by the BGW on its main
thread via `PerformCheckpoint`. The BGW uses an atomic 5-phase sequence:
write to temp files, fsync, rename, fsync directory, then advance the
replication slot. Save uses `MAIN_FORKNUM` unconditionally and skips
temp relations (they never serialize).

---

## 5. Performance

> **Important:** The numbers in this section are **speculative** — they
> are informed estimates based on inspection of the code, the SVS
> algorithm complexity, and comparable graph-index implementations (HNSW
> incremental insert, DiskANN SSDnn). They have **not** been measured
> on this branch at the time of writing. Validate with your own
> benchmarks before planning capacity.

### 5.1 Model

Let:
- `N` = number of live vectors in the index
- `D` = vector dimensionality
- `R` = `graph_degree`
- `L` = `build_window_size` (typically `2R`)
- `W` = `search_window_size`
- `b` = incoming batch size of writes between SELECTs
- `d` = fraction of vectors deleted since last compact

### 5.2 INSERT latency

| Operation | Static (svs-integration/master) | Dynamic (this PR) |
|---|---|---|
| `INSERT` itself | `O(1)` — just marks cache invalid | `O(L·D) + O(R)` — one greedy search + neighbor insertion |
| Next `SELECT` (rebuild cost) | `O(N·L·D)` — full rebuild from heap | `O(W·D)` — normal query |
| Amortized cost of `b` inserts + one SELECT | `O(N·L·D)` | `O(b·L·D + W·D)` |

**Crossover.** When `b < N/something` (roughly when the batch is small
relative to the dataset), dynamic wins by a factor proportional to
`N/b`. Even at `b ≈ N`, dynamic is no slower than static because
incremental insert is the same algorithm as rebuild, applied row-wise.
Dynamic loses to static only in the contrived case where every insert
is followed by a `REINDEX` anyway — in which case the extra per-insert
work is wasted.

**Expected magnitudes (1M × 1536D, `R=64`, `L=128`, `W=100`).**
- Static per-insert amortized cost for mixed workload (INSERTs + SELECTs):
  dominated by the first SELECT's rebuild — tens of seconds.
- Dynamic per-insert cost: estimated sub-millisecond per vector
  (`SVSAddPoints` on a single point), plus small per-index LWLock
  overhead.
- **Expected throughput delta:** 3–4 orders of magnitude for
  small-batch ingestion patterns, closing to roughly parity for
  bulk-loaded workloads where a `REINDEX` is acceptable.

### 5.3 DELETE + VACUUM latency

| Operation | Static | Dynamic |
|---|---|---|
| `VACUUM` on index with `k` dead tuples | `O(N·L·D)` — full rebuild from heap (dead tuples excluded by MVCC snapshot) | `O(k·R)` for delete + `O(N·R)` for consolidate when invoked |
| `SVSCompact` cost | n/a | `O(N·R)`, only when `d > compact_threshold_pct` |
| Amortized per-vacuum | `O(N·L·D)` | `O(k·R) + [d>threshold?O(N·R):0]` |

Dynamic's `vamanavacuumcleanup` runs `SVSConsolidate` whenever there
are pending deletes, not just at the compact threshold — so recall does not
drift upward with deletion volume. Only the physical memory reclamation
(compact) is threshold-gated.

### 5.4 Query latency (after writes)

Dynamic indexes should have steady-state query latency matching a
freshly built index after consolidation. Before consolidation, queries
on indexes with heavy deletions may see elevated latency because the
graph has more "stub" nodes (deleted entries that still appear as
candidates but are filtered at the `tidMapping` check).

**Recall impact.** SVS's consolidate operation is advertised as
preserving recall at the level of the original build. Expect recall
between `VACUUM` cycles to decay mildly (proportional to `d`) and
snap back after consolidate. If recall matters and deletion rates are
high, trigger `VACUUM` more frequently.

### 5.5 Concurrency

- **Readers scale with SVS threads** (`svs.search_num_threads`,
  capped at `nproc-1`). Searches take the per-index LWLock in
  `LW_SHARED` mode, so concurrent searches proceed together and only
  block against an in-progress exclusive writer on the same index.
- **Writers serialize per-index** via the per-index LWLock
  (`VamanaGetIndexLock`, tranche `vamana_index_rwlock`) held in
  `LW_EXCLUSIVE` mode. Two backends inserting into the same Vamana
  index will queue on that lock. Throughput under concurrent write load
  is bound by `1 / per-insert time` of the single-threaded SVS add
  path. If ingest is a bottleneck, batch writes in a single backend to
  amortize the lock acquisition cost.
- **Writers on different indexes don't serialize.** Each index has its
  own lock slot, keyed by relation OID.
- **Saves block writers for their duration.** Checkpoints run on the
  BGW main thread. While a checkpoint is in progress, INSERT and DELETE
  requests queue on their IPC slot latches and are processed once the
  checkpoint completes.

### 5.6 Memory

Dynamic indexes carry a small per-index overhead:

- The TID mapping grows with `tidMappingCapacity`, not `numVectors`.
  After many deletes without a compact, the sidecar file is sized by
  capacity, not live count. Run `VACUUM` once deletion pressure exceeds
  `svs.compact_threshold_pct` (default 10%) to reclaim. Lower the
  threshold for memory-constrained deployments with heavy delete churn;
  raise it to reduce compact frequency in read-heavy workloads that
  tolerate memory overhead.
- SVS's dynamic storage holds small bookkeeping per vector (delete
  flags, insertion metadata). A handful of bytes per vector — small
  relative to the graph itself.

### 5.7 Build time

Build time for `svs_index_build_dynamic` is dominated by the heap scan
(`PROGRESS_VAMANA_PHASE_LOAD`), which is unchanged from before.

---

## 6. Known Limitations

1. **Write serialization per index.** All inserts and vacuums on the
   same Vamana index serialize on a single per-index LWLock. High-concurrency
   write workloads should drive ingestion through a single backend that
   batches multi-row `INSERT` statements. The serialization is intentional:
   `nextExternalId` must be assigned monotonically.
2. **BGW cold-cache on first write.** If the BGW has not yet loaded the
   index (e.g. immediately after server restart), the first `INSERT`
   triggers a synchronous load or rebuild inside the BGW before the
   insert proceeds. Run a trivial `SELECT` at deployment time to
   pre-warm the BGW cache.
3. **BGW reload lag after INSERT.** After an insert the BGW's in-memory
   graph is updated synchronously (the insert blocks until the BGW ACKs).
   Subsequent `SELECT`s from any session see the updated graph immediately.
4. **`REINDEX` resets `nextExternalId`.** This is harmless for
   search but is worth knowing for anyone auditing SVS-level state.
5. **`TRUNCATE` cache coherence.** See the user guide's TRUNCATE note —
   the dynamic index does not change that behavior.
6. **Crash recovery replays from the replication slot.** On BGW
   restart, the worker loads the last checkpoint from disk and replays
   committed changes from the replication slot forward. Replay cost is
   proportional to the number of committed operations since the last
   checkpoint.
7. **No `SVSAddPoints` batching in `vamanainsert`.** Each insert call
   hands one vector to SVS. If SVS add-throughput matters, tests
   should confirm whether batching inside a single statement would
   amortize the lock + metapage overhead; current code does not.

---

## 7. Reference: New and Changed Symbols

### 7.1 Key changes

The SVS wrapper layer was extended with seven new entry points covering the dynamic index lifecycle: build, load, incremental add, delete, consolidate, compact, and ID existence check.

The metapage and in-memory cache were extended with v2 fields to track the next external ID, deleted count, and TID mapping capacity. A new atomic metapage write function updates all dynamic fields in a single WAL record.

The build path was switched from a static to a dynamic SVS build, and now creates a replication slot immediately after serialization before submitting a synchronous load request to the BGW. The insert path was rewritten from cache-invalidation to incremental per-vector addition via the BGW. The vacuum path was updated to submit batched deletes, consolidate, and threshold-gated compact requests to the BGW rather than performing them directly. The scan path was updated to load the dynamic index format and to bounds-check against TID mapping capacity, filtering soft-deleted slots during search.

Regression tests covering incremental INSERT, DELETE + VACUUM, and REINDEX were added.

### 7.2 Locking

Write/search serialization uses a per-index LWLock in shared memory, not
an advisory lock. The tranche is registered as `vamana_index_rwlock` in
`vamanaworkershmem.c`; backends and the BGW obtain the lock for a given
index via `VamanaGetIndexLock(Oid relid)`, which resolves the relation OID
to its slot in the `VamanaIndexLockSlot` array. Writers acquire it
`LW_EXCLUSIVE`; searches acquire it `LW_SHARED`.

### 7.3 Signatures

```c
/* svs_wrapper.h */
SVSIndexHandle SVSBuildDynamicIndex(SVSBuilderHandle, const float *data,
                                    const size_t *ids, int n, int *err);
SVSIndexHandle SVSLoadDynamicIndex(const char *path, const SVSBuildConfig *);
int  SVSAddPoints(SVSIndexHandle, const float *points, const size_t *ids, int n);
int  SVSDeletePoints(SVSIndexHandle, const size_t *ids, int n);
bool SVSConsolidate(SVSIndexHandle);
bool SVSCompact(SVSIndexHandle, size_t batchsize);
bool SVSHasId(SVSIndexHandle, size_t id);

/* vamana.h */
void VamanaDynamicAcquireWriteLock(Oid indexRelid);
void VamanaWriteMetaPageDynamic(Relation, uint64 nextExternalId,
                                uint32 numVectors, uint32 numDeleted,
                                uint32 tidMappingCapacity, ForkNumber);
void VamanaCacheIndex(Oid relid, SVSIndexHandle, int dimensions,
                      int graph_degree, float alpha,
                      ItemPointerData *tidMapping, int numVectors,
                      int tidMappingCapacity,
                      uint64 nextExternalId, int numDeleted);
```
