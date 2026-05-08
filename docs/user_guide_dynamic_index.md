# User Guide: Dynamic Vamana Index

> **⚠️ Disclaimer:** This is a prototype. Interfaces, parameters, and
> behavior are subject to change. See [Section 9](#9-known-limitations)
> for current limitations.

## Table of Contents

1. [Quickstart / One-Page Summary](#1-quickstart--one-page-summary)
2. [Why Dynamic? (Motivation and Background)](#2-why-dynamic-motivation-and-background)
3. [Architecture](#3-architecture)
4. [The Write Path in Detail](#4-the-write-path-in-detail)
5. [The Read Path and Soft-Delete Semantics](#5-the-read-path-and-soft-delete-semantics)
6. [Persistence and On-Disk Format](#6-persistence-and-on-disk-format)
7. [Compressed Indexes (LeanVec / LVQ)](#7-compressed-indexes-leanvec--lvq)
8. [Performance](#8-performance)
9. [Known Limitations](#9-known-limitations)
10. [Operational Runbook](#10-operational-runbook)
11. [Troubleshooting](#11-troubleshooting)
12. [Reference: New and Changed Symbols](#12-reference-new-and-changed-symbols)

---

## 1. Quickstart / One-Page Summary

**What this describes.** The Vamana index is *dynamic*: inserts are added
to the live SVS graph incrementally via `svs_index_dynamic_add_points`,
and deletes are applied during `VACUUM` via
`svs_index_dynamic_delete_points` followed by consolidate/compact. No
`REINDEX` is required after an insert or delete for the index to stay
correct.

**What you do differently.** Nothing new at the SQL level. `CREATE
INDEX ... USING vamana` and `ORDER BY ... LIMIT` queries work exactly as
before. The speed-up is automatic:

```sql
CREATE EXTENSION IF NOT EXISTS svs;

CREATE TABLE docs (id bigserial PRIMARY KEY, embedding vector(1536));
-- Build a Vamana index on the current rows
CREATE INDEX ON docs USING vamana (embedding vector_cosine_ops);

-- Inserts are now incrementally added to the live graph
INSERT INTO docs (embedding) VALUES ('[...]');
-- Immediately searchable, no REINDEX:
SELECT id FROM docs ORDER BY embedding <=> '[...]' LIMIT 5;

-- Deletes need a VACUUM to remove entries from the graph
DELETE FROM docs WHERE id = 42;
VACUUM docs;
```

**Behavioral highlights (as shipped on this branch).**

| Aspect | Behavior |
|---|---|
| `INSERT` path | `SVSAddPoints` on the cached index |
| Next `SELECT` after `INSERT` | Serves from updated graph |
| `DELETE` + `VACUUM` path | `SVSDeletePoints` + consolidate/compact |
| Serialization | `svs_index_save_dynamic` (directory on disk) |
| Metapage fields | `nextExternalId`, `numDeleted`, `tidMappingCapacity` |
| Concurrency | Per-index advisory lock (`'DYNA'`) serializes writers |
| `REINDEX` needed for correctness? | No |

**Edge cases to know about.**

- The first `INSERT` after a cold start (server restart, new backend, stale
  cache) falls back to cache invalidation; the next query rebuilds and
  caches a dynamic handle, and subsequent inserts use the fast path.
- Writes are serialized per index by a PostgreSQL advisory lock. For
  high-concurrency ingest, concurrent `INSERT`s on the same index are
  throughput-bound by that lock.
- Deletes are *soft*: `SVSDeletePoints` marks entries deleted and
  `VACUUM`'s cleanup phase runs `SVSConsolidate` (always) and
  `SVSCompact` (only when deletion pressure exceeds
  `vamana.compact_threshold_pct`, default 10%) to reclaim space.
- External IDs are never reused. `nextExternalId` in the metapage grows
  monotonically for the life of the index. `REINDEX` resets it.

---

## 2. Why Dynamic? (Motivation and Background)

### 2.1 Why row-by-row inserts matter

PostgreSQL exposes vector indexes through `INSERT` and `DELETE`, which
arrive one row at a time. A graph-based ANN index that only supports
build-from-scratch would either need to rebuild on every mutation
(`O(N)` per SELECT after any write) or require operators to call
`REINDEX` manually after every batch of changes. Neither is acceptable
for workloads where rows arrive continuously.

The SVS dynamic API solves this by maintaining a mutable graph that
accepts incremental adds and soft-deletes. The pgvector integration
layer in this module wires those primitives into PostgreSQL's index AM
interface.

### 2.2 What the SVS dynamic API offers

Intel SVS exposes a second set of entry points for mutable indexes:

- `svs_index_build_dynamic(builder, data, ids, n, blocksize_bytes, error)`
  — builds a graph that accepts later mutations.
- `svs_index_dynamic_add_points(index, data, ids, n, error)` — adds new
  vectors, wiring them into the existing graph.
- `svs_index_dynamic_delete_points(index, ids, n, error)` — soft-deletes
  entries (their graph slots are marked but not reclaimed).
- `svs_index_dynamic_consolidate(index, error)` — patches graph edges
  that pointed at deleted entries so searches stay connected.
- `svs_index_dynamic_compact(index, batchsize, error)` — garbage-collects
  deleted slots and reclaims memory; preserves external IDs.
- `svs_index_dynamic_has_id(index, id, out, error)` — predicate used for
  bounded sanity checks.
- `svs_index_save_dynamic` / `svs_index_load_dynamic` — serialization
  that round-trips the mutable state.

The wrapper in `src/svs_wrapper.c` exposes each of these as a thin
PostgreSQL-friendly shim (`SVSBuildDynamicIndex`, `SVSAddPoints`,
`SVSDeletePoints`, `SVSConsolidate`, `SVSCompact`, `SVSHasId`, and
`SVSLoadDynamicIndex`). See `src/svs_wrapper.h:91-100`.

---

## 3. Architecture

### 3.1 Where dynamic behavior lives

```
┌───────────────────────────────────────────────────────────────┐
│ vamanabuild.c                                                 │
│   vamanabuild() ──► SVSBuildDynamicIndex()                    │
├───────────────────────────────────────────────────────────────┤
│ vamanainsert.c                                                │
│   vamanainsert()                                              │
│     ├─ if cache absent/invalid: invalidate → fall back        │
│     └─ else: advisory lock, SVSAddPoints, update metapage     │
├───────────────────────────────────────────────────────────────┤
│ vamanavacuum.c                                                │
│   vamanabulkdelete()                                          │
│     ├─ advisory lock                                          │
│     ├─ walk tidMapping, collect dead IDs via PG callback      │
│     └─ SVSDeletePoints + metapage update                      │
│   vamanavacuumcleanup()                                       │
│     ├─ SVSConsolidate (always if numDeleted > 0)              │
│     └─ SVSCompact (gated by vamana.compact_threshold_pct)     │
├───────────────────────────────────────────────────────────────┤
│ vamanautils.c                                                 │
│   VamanaRebuildFromTable() ──► SVSBuildDynamicIndex()         │
│   VamanaDynamicAcquireWriteLock() (new)                       │
│   VamanaWriteMetaPageDynamic() (new)                          │
├───────────────────────────────────────────────────────────────┤
│ vamanascan.c                                                  │
│   LoadIndexFromPages()                                        │
│     └─ SVSLoadDynamicIndex on the saved directory             │
│   SVSSearch skips InvalidItemPointer slots (soft-delete)      │
└───────────────────────────────────────────────────────────────┘
```

### 3.2 Metapage layout

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
  backends; inserters read it under an advisory lock, pass the value to
  `SVSAddPoints`, and write `value+1` back.
- `numDeleted` — drives the `SVSCompact` decision threshold (see
  `vamana.compact_threshold_pct`) and reports deletion pressure.
- `tidMappingCapacity` — after deletes, the TID mapping array has
  holes. `numVectors` tracks live entries; `tidMappingCapacity` tracks
  the allocated length (which is what the sidecar `tidmap.bin` file
  serializes). Search uses the capacity as its upper bound, then
  filters `InvalidItemPointer` slots.

### 3.3 In-memory cache (`VamanaIndexCache`)

The backend-private cache mirrors the metapage and adds a few runtime
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
> authoritative. Inserts always re-read the metapage under the advisory
> lock before assigning an ID (see `vamanainsert.c:74-75`). This
> prevents two backends from ever observing the same "next ID" even if
> their caches fall out of sync.

---

## 4. The Write Path in Detail

### 4.1 INSERT (`vamanainsert.c`)

```
vamanainsert(index, values, isnull, heap_tid, ...)
  │
  ├─ cache = VamanaGetCache(relid)
  │   └── if NULL/invalid/handle-NULL → VamanaInvalidateCache; return
  │       (this is the "cold cache" fallback)
  │
  ├─ vec = PG_DETOAST_DATUM_COPY(values[0])     // aligned, standalone palloc
  │
  ├─ VamanaDynamicAcquireWriteLock(relid)       // blocking advisory lock
  │
  ├─ VamanaReadMetaPage(index, &meta)           // authoritative nextExternalId
  ├─ externalId = meta.nextExternalId
  │
  ├─ added = SVSAddPoints(cache->svsIndex, vec->x, &externalId, 1)
  │   └── on failure → invalidate cache; return
  │
  ├─ grow tidMapping if externalId >= capacity (doubling strategy)
  ├─ tidMapping[externalId] = heap_tid
  │
  ├─ cache->nextExternalId = externalId + 1
  ├─ cache->numVectors++
  ├─ cache->needsSave = true
  ├─ VamanaWriteMetaPageDynamic(...)            // WAL-logged, single page
  │
  └─ signal the background worker to reload (if enabled)
```

Key invariants and observations:

- The advisory lock key is `VAMANA_DYNAMIC_WRITE_LOCK_KEY = 0x44594E41`
  ("DYNA" in ASCII), scoped by `(MyDatabaseId, indexRelid)` so it is
  per-index and per-database. It is transaction-scoped (released at
  commit/abort).
- The lock only serializes **writers on the same index**. Readers are
  unblocked — `SVSSearch` runs concurrently with writers and sees a
  coherent snapshot of the SVS graph (SVS internals are thread-safe).
- `SVSAddPoints` is called **before** any local state is mutated. If it
  fails, nothing in the cache has moved, so the cheap recovery path of
  `VamanaInvalidateCache` is safe.
- `repalloc` of `tidMapping` happens in `TopMemoryContext` so the
  cache-pinned allocation survives past the inserting transaction.
  Capacity grows by doubling (never shrinks).
- The metapage write goes through `GenericXLogFinish`, so the four v2
  fields update atomically in one WAL record.
- `needsSave = true` defers serialization. The actual
  `VamanaSaveIndexToDisk` call runs later from `vamanaendscan`, the
  vacuum cleanup path, or the background worker — never from the insert
  hot path.

### 4.2 DELETE + VACUUM (`vamanavacuum.c`)

`vamanabulkdelete` receives PostgreSQL's dead-tuple callback and walks
the TID mapping:

```
vamanabulkdelete(info, stats, callback, state)
  │
  ├─ cache = VamanaGetCache(relid)
  │   └── if invalid/cold cache → invalidate + NOTICE; return
  │
  ├─ VamanaDynamicAcquireWriteLock(relid)
  │
  ├─ deadIds[] = palloc(tidMappingCapacity * size_t)
  ├─ for i in 0 .. tidMappingCapacity-1:
  │     tip = &tidMapping[i]
  │     if !ItemPointerIsValid(tip): continue     // already-dead slot
  │     if callback(tip, state):                  // PG says this heap TID is dead
  │         deadIds[numDead++] = i
  │         ItemPointerSetInvalid(tip)            // mark slot immediately
  │
  ├─ if numDead > 0:
  │     SVSDeletePoints(cache->svsIndex, deadIds, numDead)
  │     │   └── on failure → invalidate cache + WARNING; stats returned
  │     cache->numDeleted += numDead
  │     cache->numVectors -= numDead
  │     VamanaWriteMetaPageDynamic(...)
  │
  └─ stats->tuples_removed = numDead
     stats->num_index_tuples = cache->numVectors
```

`vamanavacuumcleanup` runs after `vamanabulkdelete` completes:

- `SVSConsolidate` is called whenever `numDeleted > 0`. This patches
  graph edges that used to point at deleted entries so the remaining
  graph stays connected. Recall of the remaining vectors is preserved.
- `SVSCompact(index, batchsize=0)` is called **only** when
  `numDeleted / numVectors > vamana.compact_threshold_pct / 100`
  (default 10%). Compact physically reclaims slot
  memory. Crucially, SVS's compact **preserves external IDs**, so the
  backend's `tidMapping` array does not need to be rewritten.
- After compact succeeds, `cache->numDeleted` is reset to 0.

### 4.3 Why the slot is marked invalid *before* SVS delete succeeds

Look at `vamanavacuum.c:74-80`:

```c
if (callback(tip, callback_state))
{
    deadIds[numDead++] = (size_t) i;
    /* Mark the slot invalid immediately so searches skip it. */
    ItemPointerSetInvalid(tip);
}
```

The `ItemPointerSetInvalid` call runs **before** `SVSDeletePoints`. If
SVS then fails, the cache is invalidated anyway (the subsequent query
triggers a rebuild from the heap — the heap already reflects the
deletion). Leaving the TID valid in the interim would risk returning a
dead row in a concurrent SELECT that raced the delete path.

### 4.4 Cold-cache fallback (INSERT)

`vamanainsert` can observe `cache == NULL || !isValid || svsIndex == NULL`.
In all three cases it invalidates and returns. The trigger conditions:

1. **`cache == NULL`** — backend is brand-new and has never searched or
   loaded this index.
2. **`!cache->isValid`** — a prior invalidation (from a TRUNCATE, DROP,
   etc.) cleared the slot.
3. **`cache->svsIndex == NULL`** — the slot exists but the handle has
   been freed (rare; e.g., mid-eviction).

After the fallback, the next `ORDER BY ... LIMIT` triggers
`LoadIndexFromPages` → on miss, `VamanaRebuildFromTable`, which builds
a fresh dynamic index. Subsequent inserts use the fast path.

---

## 5. The Read Path and Soft-Delete Semantics

`SVSSearch` (`src/svs_wrapper.c:469-581`) is the query-time hot path.
Two changes affect reads under dynamic indexes:

### 5.1 Bounds check widened to `tidMappingCapacity`

Static indexes always had `numVectors == tidMappingCapacity`. Dynamic
indexes can have `tidMappingCapacity > numVectors` because deleted
slots stay allocated (as holes) until compaction. SVS may return
indices up to the full capacity, and the search loop now bounds-checks
against `cachedIndex->tidMappingCapacity` rather than `numVectors`:

```c
/* src/svs_wrapper.c:548 */
if (vector_index >= (size_t) cachedIndex->tidMappingCapacity)
    ereport(ERROR, ...);
```

### 5.2 Soft-delete filtering

The search loop skips any slot whose TID is `InvalidItemPointer`:

```c
/* src/svs_wrapper.c:560-561 */
if (!ItemPointerIsValid(&cachedIndex->tidMapping[vector_index]))
    continue;
```

This is the read-side half of the bulk-delete protocol in [§4.2](#42-delete--vacuum-vamanavacuumc).
Between `VACUUM`'s write-lock release and the next `SVSConsolidate`,
SVS may still surface the deleted vectors as candidates; the filter
ensures they never reach the client.

### 5.3 `k` vs. `out`

Because the filter can drop results, the loop uses a separate `out`
counter rather than the raw SVS index `i`. The returned `num_results`
is the number of *surviving* results, which may be less than `k`. This
matches the existing pgvector contract for sparse result sets.

---

## 6. Persistence and On-Disk Format

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
(see `VamanaMarkIndexSaved` in `vamanautils.c:504-537`).

### 6.1 Load path (`vamanascan.c:30-175`)

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

### 6.2 Save path (`vamanautils.c:549-643`)

Save is protected by a **separate** advisory lock
(`VAMANA_SAVE_LOCK_KEY`, keynum `2`), non-blocking. Two backends racing
to save is common — the winner saves, the loser no-ops, and both
in-memory caches stay valid. Save uses `MAIN_FORKNUM` unconditionally
and skips temp relations (they never serialize).

---

## 7. Compressed Indexes (LeanVec / LVQ)

Dynamic indexes work with all compression types. Pass standard float32
vectors — SVS compresses them automatically.

**Training data requirement.** LeanVec and LVQ use the vectors present
at index creation time as training data for their compression matrices.
Building an index on a table with very few rows produces an index with
poor recall (no error is raised).

Recommended minimums before `CREATE INDEX`:
- **LeanVec** (`compression_type = 1`): 100,000 rows (10,000 minimum)
- **LVQ** (`compression_type = 2`): 10,000 rows

A WARNING is emitted at build time if the row count is below these
thresholds. To fix, load more data and run `REINDEX INDEX`.

```sql
-- Example: WARNING fires because the table has only 100 rows
CREATE INDEX ON docs USING vamana (embedding vector_cosine_ops)
  WITH (compression_type = 1);
-- WARNING:  building LeanVec index with only 100 vectors;
--           recall may be poor (recommend >= 100000, minimum 10000)
```

The same WARNING fires in `VamanaRebuildFromTable` (the cold-start
rebuild path).

---

## 8. Performance

> **Important:** The numbers in this section are **speculative** — they
> are informed estimates based on inspection of the code, the SVS
> algorithm complexity, and comparable graph-index implementations (HNSW
> incremental insert, DiskANN SSDnn). They have **not** been measured
> on this branch at the time of writing. Validate with your own
> benchmarks before planning capacity.

### 8.1 Model

Let:
- `N` = number of live vectors in the index
- `D` = vector dimensionality
- `R` = `graph_degree`
- `L` = `build_window_size` (typically `2R`)
- `W` = `search_window_size`
- `b` = incoming batch size of writes between SELECTs
- `d` = fraction of vectors deleted since last compact

### 8.2 INSERT latency

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
  (`SVSAddPoints` on a single point), plus small advisory-lock
  overhead.
- **Expected throughput delta:** 3–4 orders of magnitude for
  small-batch ingestion patterns, closing to roughly parity for
  bulk-loaded workloads where a `REINDEX` is acceptable.

### 8.3 DELETE + VACUUM latency

| Operation | Static | Dynamic |
|---|---|---|
| `VACUUM` on index with `k` dead tuples | `O(N·L·D)` — full rebuild from heap (dead tuples excluded by MVCC snapshot) | `O(k·R)` for delete + `O(N·R)` for consolidate when invoked |
| `SVSCompact` cost | n/a | `O(N·R)`, only when `d > compact_threshold_pct` |
| Amortized per-vacuum | `O(N·L·D)` | `O(k·R) + [d>threshold?O(N·R):0]` |

Dynamic's `vamanavacuumcleanup` runs `SVSConsolidate` whenever there
are pending deletes, not just at the compact threshold — so recall does not
drift upward with deletion volume. Only the physical memory reclamation
(compact) is threshold-gated.

### 8.4 Query latency (after writes)

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

### 8.5 Concurrency

- **Readers scale with SVS threads** (`vamana.search_num_threads`,
  capped at `nproc-1`). Readers do **not** hold the dynamic write
  lock.
- **Writers serialize per-index** via
  `VAMANA_DYNAMIC_WRITE_LOCK_KEY`. Two backends inserting into the
  same Vamana index will queue on the advisory lock. Throughput under
  concurrent write load is bound by `1 / per-insert time` of the
  single-threaded SVS add path. If ingest is a bottleneck, batch
  writes in a single backend to amortize the lock acquisition cost.
- **Writers on different indexes don't serialize.** The lock is keyed
  by relation OID.
- **Writers don't block saves.** `VAMANA_SAVE_LOCK_KEY` is a separate
  key, intentionally decoupled (see the comment at
  `vamanautils.c:646-652`). A backend can save the index at
  `vamanaendscan` while another backend continues to insert.

### 8.6 Memory

Dynamic indexes carry a small per-index overhead:

- The TID mapping grows with `tidMappingCapacity`, not `numVectors`.
  After many deletes without a compact, the sidecar file is sized by
  capacity, not live count. Run `VACUUM` once deletion pressure exceeds
  `vamana.compact_threshold_pct` (default 10%) to reclaim. Lower the
  threshold for memory-constrained deployments with heavy delete churn;
  raise it to reduce compact frequency in read-heavy workloads that
  tolerate memory overhead.
- SVS's dynamic storage holds small bookkeeping per vector (delete
  flags, insertion metadata). A handful of bytes per vector — small
  relative to the graph itself.

### 8.7 Build time

Build time for `svs_index_build_dynamic` is dominated by the heap scan
(`PROGRESS_VAMANA_PHASE_LOAD`), which is unchanged from before.

---

## 9. Known Limitations

1. **Write serialization per index.** All inserts and vacuums on the
   same Vamana index serialize on a single advisory lock. High-concurrency
   write workloads should drive ingestion through a single backend that
   batches multi-row `INSERT` statements. The lock is intentional:
   `nextExternalId` must be assigned monotonically.
2. **Cold-cache fallback on first write.** If no backend has queried
   the index since server start (or since the last invalidation), the
   first `INSERT` triggers a full rebuild on the next `SELECT`. Warm
   the cache with a trivial query at deployment time to avoid this.
3. **Multi-backend cache coherence.** After an `INSERT`, only the
   inserting backend's cache reflects the new vector. Other backends
   see their cached (stale) SVS handle until either (a) the background
   worker picks up the reload signal, or (b) their cache is
   invalidated by another event. New rows *are* persisted and
   discoverable — peer backends simply may not return them until
   reload. The background worker mitigates this; direct-mode
   deployments should be aware.
4. **`REINDEX` resets `nextExternalId`.** This is harmless for
   search but is worth knowing for anyone auditing SVS-level state.
5. **`TRUNCATE` cache coherence.** See the existing user guide's
   TRUNCATE note — the dynamic index does not change that behavior.
6. **No incremental update path in the worker itself.** The worker
   reloads the whole index when signaled. For very large indexes
   under constant write load, this can be expensive. Reload frequency
   is bounded by the worker's loop cadence.
7. **No `SVSAddPoints` batching in `vamanainsert`.** Each insert call
   hands one vector to SVS. If SVS add-throughput matters, tests
   should confirm whether batching inside a single statement would
   amortize the lock + metapage overhead; current code does not.

---

## 10. Operational Runbook

### 10.1 Typical deployment flow

```sql
-- 1. Build (or migrate) the index
CREATE INDEX CONCURRENTLY docs_vamana ON docs USING vamana (embedding vector_cosine_ops);

-- 2. Warm the cache (one trivial SELECT per backend that will write)
SELECT id FROM docs ORDER BY embedding <=> '[0,0,...]' LIMIT 1;

-- 3. Begin serving writes
INSERT INTO docs (embedding) VALUES ('[...]');
```

### 10.2 Tuning `vamana.compact_threshold_pct`

The percent-deleted threshold that triggers `SVSCompact` during VACUUM
cleanup. Default 10. Range 0-100.

- **0**: compact on every VACUUM with any pending deletes. Tightest
  memory footprint; highest VACUUM cost.
- **10** (default): compact once deleted entries exceed 10% of live
  vectors. Balances memory and VACUUM cost.
- **100**: disable compact entirely. Consolidate still runs (graph
  recall is preserved) but memory for deleted slots is never reclaimed
  without `REINDEX`.

Lower for memory-constrained deployments with heavy delete churn.
Raise for write-heavy workloads where VACUUM latency matters more than
memory. Change takes effect on the next `VACUUM` — no restart required.

### 10.3 When to REINDEX

You do **not** need periodic `REINDEX` for correctness. You might still
choose to `REINDEX` if:

- `numDeleted / numVectors` has grown unusually large between vacuums
  (unlikely to happen if autovacuum is running).
- You've observed measurable recall drop in production after a long
  write horizon. Vamana graphs accumulate a small amount of topological
  debt over thousands of incremental inserts. A fresh `svs_index_build`
  produces the optimal graph for the current data.
- You need to change a build-time parameter (`graph_degree`,
  `compression_type`, etc.).

### 10.4 Monitoring

| What | How |
|---|---|
| Live vs. deleted count | Inspect metapage (currently no SQL-level view; see [§12](#12-reference-new-and-changed-symbols)). |
| Write serialization pressure | `pg_locks` for advisory locks on `(classid=0, objid=<oid>, objsubid=2)`. |
| Rebuild frequency | Grep server logs for `rebuilding vamana index from table data`. A dynamic index should see this only on cold start, after restart, or after TRUNCATE/REINDEX. |
| Worker reload signals | Grep for `vamana worker: reloading index` or `vamana worker: reload_all set`. |

### 10.5 Key log messages

| Situation | Log message |
|---|---|
| Index loaded from disk | `loading vamana index <oid> from "<path>"` |
| Index reloaded by worker | `vamana worker: reloading index <oid>` |
| Rebuild from heap (cold miss) | `rebuilding vamana index from table data` |
| LeanVec/LVQ training data warning | `building LeanVec index with only N vectors; recall may be poor` (WARNING) |
| Consolidate/compact failure | `vamana index <oid>: SVS consolidate failed during vacuum cleanup` (WARNING) |

---

## 11. Troubleshooting

### 11.1 An INSERT does not appear in a SELECT from another session

**Most common cause:** the other backend's cache has a stale SVS
handle (multi-backend cache coherence, [§9](#9-known-limitations)).

**Check:** is the background worker enabled?
```sql
SHOW vamana.worker_enabled;
```

**Fix options, in order of preference:**
1. Enable the worker so reload signals propagate.
2. Have the other backend reconnect (new backends rebuild the cache on
   first query, picking up the current save directory or rebuilding
   from the heap).
3. Force-invalidate with `REINDEX`.

### 11.2 A SELECT returns fewer than `LIMIT` rows after many DELETEs

**Expected**: `SVSSearch` filters soft-deleted slots and the returned
count can be less than `k`. Run `VACUUM` to trigger consolidate.

If the underfill persists after `VACUUM`, check the server log for
`SVS consolidate failed` warnings. If consolidation keeps failing, as
a recovery, `REINDEX INDEX CONCURRENTLY <idx>`.

### 11.3 INSERT throughput drops at high concurrency

**Cause:** advisory-lock serialization on
`VAMANA_DYNAMIC_WRITE_LOCK_KEY`. Throughput is bounded by
single-threaded SVS add.

**Fix:**
- Batch rows in multi-row `INSERT` statements from a single backend.
- Consider splitting logically independent datasets across multiple
  partitions (each partition is a different relation → different
  advisory lock key).

### 11.4 INSERT errors out on an unknown-to-SVS condition

The code path in `vamanainsert.c:84-89` catches `SVSAddPoints` failure
by invalidating the cache: the insert itself returns success, and the
next SELECT rebuilds. No user-visible error. If you see `WARNING: SVS
dynamic add points failed:` in the server log frequently, capture the
SVS error message — it typically indicates dimension mismatch, an SVS
ID collision (should not happen given the metapage-driven ID
assignment), or an out-of-memory condition.

### 11.5 "Index will be rebuilt from table on next query" NOTICE after VACUUM

This fires from `vamanavacuum.c:49`. It means the cache was invalid or
not yet dynamic when `VACUUM` ran. A typical cause is that the cache
has not been loaded since the last server restart. Run any `SELECT ...
ORDER BY vec <-> ...` to warm the cache and the next `VACUUM` will use
the incremental path.

---

## 12. Reference: New and Changed Symbols

### 12.1 Files (net of this PR)

- `src/svs_wrapper.{c,h}` — 7 new wrapper functions: `SVSBuildDynamicIndex`, `SVSLoadDynamicIndex`, `SVSAddPoints`, `SVSDeletePoints`, `SVSConsolidate`, `SVSCompact`, `SVSHasId`.
- `src/vamana.h` — v2 metapage fields, v2 cache fields, `VAMANA_DYNAMIC_WRITE_LOCK_KEY`, `VamanaDynamicAcquireWriteLock`, `VamanaWriteMetaPageDynamic`, extended `VamanaCacheIndex` signature.
- `src/vamanabuild.c` — switched to `SVSBuildDynamicIndex`, populates dynamic cache fields.
- `src/vamanainsert.c` — rewritten from stub-invalidate to incremental `SVSAddPoints`.
- `src/vamanavacuum.c` — `vamanabulkdelete` now deletes incrementally; `vamanavacuumcleanup` runs consolidate + threshold-gated compact.
- `src/vamanautils.c` — `VamanaRebuildFromTable` switched to dynamic build; `VamanaMarkIndexSaved` persists v2 fields; new `VamanaDynamicAcquireWriteLock` and `VamanaWriteMetaPageDynamic`; `VamanaLoadTidMap` now takes `tidMappingCapacity` so v2 TID maps with holes round-trip.
- `src/vamanascan.c` — `LoadIndexFromPages` uses `SVSLoadDynamicIndex` to restore the saved graph. `SVSSearch` bounds-checks capacity and skips `InvalidItemPointer`.
- `test/sql/vamana_dynamic.sql` + `test/expected/vamana_dynamic.out` — regression tests.

### 12.2 Constants

```c
#define VAMANA_DYNAMIC_WRITE_LOCK_KEY  ((uint32) 0x44594E41U)  /* 'DYNA' */
```

### 12.3 Signatures

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
