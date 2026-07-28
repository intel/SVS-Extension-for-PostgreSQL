# SVS Vamana Index Integration Architecture for pgvector

## Table of Contents
1. [Executive Summary](#executive-summary)
2. [Background](#background)
3. [Architecture Overview](#architecture-overview)
4. [Detailed Design](#detailed-design)
5. [ACID Compliance](#acid-compliance)
6. [GUC Parameters](#guc-parameters)
7. [Integration Points](#integration-points)
8. [Performance Considerations](#performance-considerations)

---

## 1. Executive Summary

This document describes the `svs` PostgreSQL extension, which adds a Vamana index access method backed by Intel's Scalable Vector Search (SVS) library. The extension is a standalone PostgreSQL extension that depends on pgvector (`vector` extension) for its vector types and operator classes; it does not bundle pgvector source.


---

## 2. Background

### 2.1 Intel SVS Library
- **Repository:** https://github.com/intel/ScalableVectorSearch
- **License:** Mixed — see below
- **Key Features:**
  - Vamana graph-based index (similar to HNSW)
  - Locally-adaptive Vector Quantization (LVQ) compression
  - LeanVec two-level quantization compression
  - Optimized for Intel Xeon processors (2nd gen and newer)
  - Support for float32, float16
  - Distance metrics: Euclidean, Inner Product, Cosine similarity
  - Billion-scale performance

**Licensing details:**

| Component | License |
|---|---|
| Core Vamana index (open-source SVS) | Apache 2.0 |
| LVQ and LeanVec compression | Intel Simplified Software License (binary-only, proprietary) |

LVQ and LeanVec are **not open-source**. They are distributed in binary form only and run only on Intel CPUs. The Intel Simplified Software License prohibits reverse engineering, decompilation, modification, or disassembly. See `ScalableVectorSearch/LICENSE` and `docs/non-open-source-notice.rst` in the SVS repository for the full terms.

### 2.2 Vamana Algorithm
- Graph-based approximate nearest neighbor search
- Similar to HNSW but with a single-layer graph and different construction strategy
- Uses greedy search with pruning strategies
- Research paper: [DiskANN: Fast Accurate Billion-point Nearest Neighbor Search on a Single Node](https://www.microsoft.com/en-us/research/publication/diskann-fast-accurate-billion-point-nearest-neighbor-search-on-a-single-node/) (Microsoft Research); [GitHub](https://github.com/microsoft/DiskANN)

### 2.3 Existing pgvector Index Implementations
- **HNSW:** Graph-based, supports parallel build, in-memory + on-disk phases
- **IVFFlat:** Clustering-based, k-means partitioning, probe-based search

---

## 3. Architecture Overview

### 3.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    PostgreSQL Core                          │
├─────────────────────────────────────────────────────────────┤
│  pgvector Extension (vector/halfvec/sparsevec types,        │
│  HNSW index, IVFFlat index)          [separate extension]   │
├─────────────────────────────────────────────────────────────┤
│                svs Extension  (requires = 'vector')         │
├─────────────────────────────────────────────────────────────┤
│                       Vamana Index                          │
│   vamana.c / vamanabuild.c / vamanainsert.c                 │
│   vamanascan.c / vamanavacuum.c / vamanautils.c             │
│   vamanaworker.c / vamana_undo.c                            │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
         ┌──────────────────────────────┐
         │    Intel SVS C API Wrapper   │
         │        svs_wrapper.c/h       │
         ├──────────────────────────────┤
         │  - Index Build               │
         │  - Index Search (batch)      │
         │  - Dynamic insert/delete     │
         │  - Compression (LVQ/LeanVec) │
         └──────────────────────────────┘
                        │
                        ▼
         ┌──────────────────────────────┐
         │  Intel SVS Shared Library    │
         │  libsvs_c_api.so             │
         └──────────────────────────────┘
```

### 3.2 Component Structure

**Core Implementation Areas:**

The extension entry point initializes the access method and registers GUCs, the object-access hook, and the background worker at server start. The index access method handler implements the PostgreSQL AM interface and dispatches to the appropriate subsystem for each operation.

The build subsystem performs a full heap scan, buffers all vectors in memory, calls the SVS dynamic build API to construct the mutable graph, serializes it to disk, creates the replication slot, and submits a synchronous LOAD request to the BGW before returning. The insert subsystem routes each incoming vector through the BGW via IPC, where it is added incrementally to the live graph and recorded in the per-transaction undo log. The scan subsystem executes ANN queries by submitting search requests to the BGW and mapping returned SVS indices back to heap TIDs via the TID mapping. The vacuum subsystem collects dead TIDs from the heap callback and submits batched delete, consolidate, and compact requests to the BGW.

The BGW subsystem owns the in-memory SVS index state for all indexes in the database, processes IPC slots from backends (search, insert, delete, maintenance), manages the replication slot, and performs periodic checkpoints. The undo log subsystem records external IDs inserted within each transaction and submits compensating BGW deletes on transaction abort. The SVS wrapper layer provides a thin, PostgreSQL-friendly interface over the Intel SVS C API for all graph operations.

**Test Coverage:**

Regression tests cover basic CRUD operations, all distance metrics, all compression types, GUC boundary values, incremental INSERT and DELETE + VACUUM cycles, and REINDEX. TAP tests cover index persistence across restarts, crash recovery, background worker lifecycle, batch search correctness, concurrent query isolation, and LWLock slot leak detection.

---

## 4. Detailed Design

### 4.1 Design Choice: SVS C API Batch Build

SVS provides a high-level batch build API with internal parallelism management.

**Implementation characteristics:**
- **SVS manages parallelism internally** via threads
- **No manual shared memory management** required for build
- **PostgreSQL passes thread count** via `max_parallel_maintenance_workers` for build operations and `svs.search_num_threads` for search operations
- **Dynamic index:** Uses `svs_index_build_dynamic` to produce a mutable index; INSERT calls `SVSAddPoints` for incremental updates, DELETE + VACUUM calls `SVSDeletePoints` with consolidation and compaction
- **Must buffer vectors:** All vectors loaded into memory before build

### 4.2 On-Disk Serialization

After the SVS batch build completes, the index is serialized to a directory on the filesystem using `VamanaGetIndexSavePath()`. The path is keyed by the index's relation OID. The metapage stores `hasSavedIndex`, `indexDataBlkno`, and `indexDataSize` to track serialization state. Immediately after serialization, `vamanabuild` creates a logical replication slot (`vamana_<db>_<idx>`) with `confirmed_flush_lsn` set to the current WAL flush position. This anchors the slot LSN to the exact point where the on-disk state is complete, ensuring crash recovery replays only changes committed after that point.

On BGW startup, `LoadIndexFromPages()` attempts to read each saved index from disk before accepting any requests. If no saved copy exists, `VamanaRebuildFromTable()` performs an in-memory rebuild from the heap. Loading also restores the TID map sidecar file (`tidmap.bin`, one `ItemPointerData` per allocated slot, written atomically via temp-file + rename) and the metapage's dynamic-index fields (`tidMappingCapacity`, `nextExternalId`, `numDeleted`) into the in-memory cache. `hasSavedIndex` and the dynamic fields are flipped to their final values together, in a single WAL-logged transaction, only after the on-disk files are durable.

An object-access hook (`VamanaInstallObjectAccessHook`) cleans up the on-disk save directory when an index or its parent table is dropped.

### 4.3 Insert and Vacuum Behavior

**Inserts:** `vamanainsert` calls `VamanaWorkerWaitUntilAvailable` before submitting, then routes the insert through the background worker (slot kind `VAMANA_SLOTKIND_INSERT`). The worker calls `SVSAddPoints` to add the new vector incrementally to the live in-memory index. External IDs are allocated from a counter held in the BGW's in-memory cache (`cache->nextExternalId`); the latest value is written back to the metapage by `VamanaWriteMetaPageDynamic` so the counter survives restart. The inserting backend records the new external ID in the per-transaction undo log (`VamanaUndoAppend`); on transaction ABORT, the registered XactCallback submits a BGW DELETE for each logged ID to roll back the in-memory graph state. All indexes are born dynamic; there is no static-only fallback path for inserts.

If the worker is up but hasn't loaded a given index yet (e.g. immediately after server restart, before `LoadAllIndexes` reaches it), the first insert against that index triggers a synchronous load via `VamanaWorkerGetOrLoadIndex`: try `LoadIndexFromPages`, falling back to `VamanaRebuildFromTable` if no saved copy exists. Subsequent inserts find the index already cached and take the fast path.

**Vacuum:** `vamanabulkdelete` iterates the TID mapping, calls PostgreSQL's dead-tuple callback for each live entry, and batches dead IDs to the BGW via `VamanaWorkerSubmitDelete`. `vamanavacuumcleanup` submits `CONSOLIDATE` and `COMPACT` requests to the BGW via `VamanaWorkerSubmitMaintenance`. The BGW calls `SVSDeletePoints`, `SVSConsolidate`, and `SVSCompact` respectively, and updates the metapage counters atomically after each operation.

**Known Limitation:** `PREPARE TRANSACTION` (two-phase commit / 2PC) is not supported on any transaction that has inserted into a Vamana index. The undo log implementation raises `ERRCODE_FEATURE_NOT_SUPPORTED` at prepare time. This is a fundamental constraint of the in-memory undo log design: prepared state cannot be persisted to disk and resumed by a later `COMMIT PREPARED`. Users with `max_prepared_transactions > 0` or distributed 2PC coordinators (e.g., Citus, XA drivers) must avoid issuing `PREPARE TRANSACTION` on transactions that touch Vamana indexes.

### 4.4 Background Worker

The background worker implements a background process that holds the SVS index permanently and serves all backends via shared memory. The worker is **always registered** when the extension is loaded via `shared_preload_libraries`; there is no opt-in GUC to enable or disable it.

**Architecture:**
- A single PostgreSQL background worker connects to `svs.worker_database` at startup and loads all Vamana indexes for that database
- Shared memory region (`VamanaWorkerShmem`) contains a per-backend slot array plus variable-length areas for query vectors, result TIDs, and distances
- Each slot has a kind (`VAMANA_SLOTKIND_SEARCH`, `_INSERT`, `_DELETE`, `_MAINTENANCE`); backends set the kind and data, set status `PENDING`, and wait on a shared latch
- The worker drains all pending slots each cycle: SEARCH slots are batched and dispatched to `SVSSearch`; write slots (`INSERT`, `DELETE`, `MAINTENANCE`) are dispatched one at a time via `VamanaWorkerProcessWriteSlot`
- If the worker is unavailable or startup times out (controlled by `svs.worker_startup_timeout_ms`), the backend throws an error rather than silently falling back
- Per-index LWLocks (`VamanaIndexLockSlot`, up to `VAMANA_MAX_INDEXES = 64` live indexes) serialize concurrent write operations within the worker. Writers acquire the lock `LW_EXCLUSIVE`; searches acquire it `LW_SHARED`, so concurrent searches proceed together and only block against an in-progress writer on the same index
- Crash recovery: the worker restarts automatically after `svs.worker_restart_time` seconds. While the worker is down, backends that attempt index operations receive an ERROR (no silent fallback). On restart, the worker loads the last checkpoint from disk, opens the persisted replication slot, and replays all committed changes from the slot's `restart_lsn` forward before accepting any requests
- Reload signaling: for edge cases such as TRUNCATE or REINDEX, backends write to `reloadRequests[]` to signal index invalidation; the worker performs a full reload on its next cycle. Normal write-path state synchronization uses replication slot replay, not reload signals

**Checkpoint and durability:** The BGW periodically checkpoints the in-memory SVS graph to disk using an atomic 5-phase sequence: write to temp files, fsync, rename, fsync directory, advance the replication slot. The slot advance is the final step — it marks the on-disk state as durable and bounds the WAL that PostgreSQL must retain. Between checkpoints, the BGW continuously applies committed changes from the slot to the in-memory graph. Checkpoint frequency is governed by the debounce GUCs (`svs.checkpoint_min_ops`, `svs.checkpoint_debounce_window`, `svs.checkpoint_max_interval`). See Section 5 for the full recovery and idempotency design.

**Transaction safety:** Inserts are logged to a per-transaction undo log. On ABORT, an XactCallback/SubXactCallback submits BGW DELETE operations for each logged insert, rolling back the in-memory graph state. On COMMIT, the undo log is discarded.

The worker is enabled by loading the extension via `shared_preload_libraries = 'vector,svs'` (requires server restart). No additional GUC is required.

### 4.5 Supported Vector Types and Operator Classes

Vamana indexes support `vector` (float32) and `halfvec` (float16) types. `sparsevec` and `bit` are not supported.

| Operator Class | Type | Distance Operator | Metric |
|---|---|---|---|
| `vector_l2_ops` | `vector` | `<->` | L2 (Euclidean) |
| `vector_ip_ops` | `vector` | `<#>` | Inner product (negated) |
| `vector_cosine_ops` | `vector` | `<=>` | Cosine |
| `halfvec_l2_ops` | `halfvec` | `<->` | L2 (Euclidean) |
| `halfvec_ip_ops` | `halfvec` | `<#>` | Inner product (negated) |
| `halfvec_cosine_ops` | `halfvec` | `<=>` | Cosine |

### 4.6 Index Build Phases

Two progress phases are reported via `pg_stat_progress_create_index`:
1. `PROGRESS_CREATEIDX_SUBPHASE_INITIALIZE` — initializing build state
2. `PROGRESS_VAMANA_PHASE_LOAD` — scanning heap and accumulating vectors

### 4.7 Dynamic Index Internals

Dynamic behavior is split across the same files listed in §3.1: `vamanabuild.c` builds via `SVSBuildDynamicIndex`; `vamanainsert.c`'s `vamanainsert` routes through `VamanaWorkerSubmitInsert`; `vamanavacuum.c`'s `vamanabulkdelete` and `vamanavacuumcleanup` route through `VamanaWorkerSubmitDelete` and `VamanaWorkerSubmitMaintenance`; `vamanautils.c` holds `VamanaRebuildFromTable` and `VamanaWriteMetaPageDynamic`; and `vamanascan.c`'s `LoadIndexFromPages` calls `SVSLoadDynamicIndex`, with `SVSSearch` skipping any slot marked `InvalidItemPointer` (soft-delete).

**Metapage fields.** Beyond the static-index fields, the metapage (`VamanaMetaPageData`) carries three fields specific to dynamic indexes: `nextExternalId`, `numDeleted`, and `tidMappingCapacity`.

- `nextExternalId` — SVS external IDs must be unique for the life of the index. The metapage is the single source of truth across backends; the BGW reads it while holding the exclusive per-index LWLock, passes the value to `SVSAddPoints`, and writes `value+1` back.
- `numDeleted` — drives the `SVSCompact` decision threshold (`svs.compact_threshold_pct`) and reports deletion pressure.
- `tidMappingCapacity` — after deletes, the TID mapping array has holes. `numVectors` tracks live entries; `tidMappingCapacity` tracks the allocated length, which is what the sidecar `tidmap.bin` file serializes. Search bounds-checks against the capacity, then filters out `InvalidItemPointer` slots.

**In-memory cache.** The BGW's per-process cache (`VamanaIndexCache`) mirrors the metapage and adds runtime-only fields (`svsIndex`, `isValid`, `memCtx`, `tidMapping`, `needsSave`). Its `nextExternalId` is a mirror of the metapage, not authoritative — the BGW re-reads the metapage while holding the exclusive per-index LWLock before assigning an ID, so assignment stays monotonic even if the cached value is stale.

### 4.8 Read Path and Soft-Delete Semantics

`SVSSearch` is the query-time hot path; two changes affect reads under dynamic indexes:

- **Bounds check widened to `tidMappingCapacity`.** Static indexes always had `numVectors == tidMappingCapacity`. Dynamic indexes can have `tidMappingCapacity > numVectors` because deleted slots stay allocated (as holes) until compaction, so SVS may return indices up to the full capacity. The search loop in `svs_wrapper.c` bounds-checks against `cachedIndex->tidMappingCapacity` rather than `numVectors`.
- **Soft-delete filtering.** The search loop skips any slot whose TID is `InvalidItemPointer`. This is the read-side half of the bulk-delete protocol (§5.2): between VACUUM's write-lock release and the next `SVSConsolidate`, SVS may still surface deleted vectors as candidates, and this filter ensures they never reach the client. Because the filter can drop results, the loop tracks a separate "surviving results" counter rather than reusing the raw SVS result index — the returned result count may be less than the requested `k`, matching the existing pgvector contract for sparse result sets.

---

## 5. ACID Compliance

The Vamana index stores its graph structure in a background worker (BGW) process using the Intel SVS library, outside PostgreSQL's normal buffer manager. This out-of-process design enables high-performance ANN search but requires explicit machinery to maintain the ACID guarantees that PostgreSQL's heap and WAL provide automatically for ordinary indexes.

| Property | Mechanism |
|---|---|
| **Atomicity** | BGW undo log for in-flight transactions; WAL slot filtering as safety net |
| **Consistency** | VACUUM as authoritative dead-entry scanner; idempotent replay prevents divergence |
| **Isolation** | Delegated to PostgreSQL's MVCC layer — dead or aborted heap TIDs are filtered by `HeapTupleSatisfiesVisibility` before results are returned, so stale graph entries never surface to queries |
| **Durability** | Logical replication slot + atomic checkpoint sequence; crash recovery replays committed changes from the slot |

### 5.1 Hybrid Design — Synchronous Writes + WAL Recovery

**Design Principle: Synchronous operations for visibility. WAL for durability and recovery.**

| Concern | Mechanism |
|---|---|
| INSERT visibility | Backend submits to BGW via IPC; BGW calls `SVSAddPoints`; backend blocks until ACK |
| DELETE visibility | VACUUM submits dead TIDs to BGW via IPC; BGW calls `SVSDeletePoints` |
| Atomicity (abort) | BGW undo log: on abort, `SVSDeletePoints` for all externalIds added in that transaction |
| Durability (crash) | Replication slot: on restart, replay committed ops from last checkpoint LSN |
| Consistency (standby) | Replication slot: standby BGW replays from slot incrementally (no IPC available) |

```
                    PRIMARY                                STANDBY
                    ───────                                ───────

Backend                  BGW                          BGW
───────                  ───                          ───
INSERT ──IPC──► SVSAddPoints (immediate)      (no IPC: read-only)
COMMIT ──WAL──► [WAL record durable]          WAL replay ──► SVSAddPoints
                     │                              ▲
                     ▼                              │
                Checkpoint:                   Replication slot:
                save graph + advance slot     read committed changes
                     │                        from slot position
                     ▼
                Crash restart:
                load last checkpoint
                replay from slot LSN
```

### 5.2 Write Path (Primary)

#### INSERT

```
Backend                         BGW
───────                         ───
BEGIN
INSERT INTO t (val) ...
  → heap_insert (WAL record written)
  → vamanainsert():
      submit (vector, heapTID) to BGW via IPC
      block until ACK                    ──► SVSAddPoints(externalId, vector)
                                              tidMapping[externalId] = heapTID
                                              record (xid, externalId) in undo log
      ◄── ACK ──────────────────────────
  → return to executor
COMMIT
  → VamanaXactCallback(COMMIT):
      clear undo entries for this xid
```

#### INSERT + ABORT

```
Backend                         BGW
───────                         ───
BEGIN
INSERT INTO t (val) ...
  → vamanainsert():
      submit to BGW via IPC
      block until ACK                    ──► SVSAddPoints(externalId, vector)
                                              record (xid, externalId) in undo log
      ◄── ACK ──────────────────────────
ROLLBACK
  → VamanaXactCallback(ABORT):
      submit undo entries to BGW         ──► SVSDeletePoints(externalId)
                                              invalidate tidMapping[externalId]
```

#### DELETE (via VACUUM)

```
VACUUM                          BGW
──────                          ───
vamanabulkdelete():
  walk index, find dead TIDs
  submit dead TIDs to BGW via IPC
  block until ACK                        ──► SVSDeletePoints(externalIds...)
                                              invalidate tidMapping entries
  ◄── ACK ──────────────────────────
vamanavacuumcleanup():
  submit CONSOLIDATE/COMPACT             ──► SVSConsolidate() / SVSCompact()
```

`vamanabulkdelete` marks each dead TID's slot `InvalidItemPointer` itself, before submitting the batched delete to the BGW — not after the BGW's `SVSDeletePoints` call succeeds. If the BGW delete then fails, the heap already reflects the deletion, so the next rebuild from the heap is still correct; leaving the TID valid in the interim would risk a concurrent SELECT returning a dead row that raced the delete path.

### 5.3 Recovery Path (Crash Restart)

```
BGW starts after crash:
  1. Load last checkpoint from disk (SVS graph + tidMapping)
  2. Open replication slot (persisted by PostgreSQL across crashes)
  3. Slot's restart_lsn = position of last checkpoint
  4. Replay all committed changes from restart_lsn to current WAL position:
       - INSERT records → SVSAddPoints (idempotency check: skip if TID exists)
       - DELETE records → SVSDeletePoints (idempotency check: skip if TID absent)
  5. Resume normal IPC operation
```

The reorder buffer guarantees only committed transactions are delivered. Aborted transactions are automatically filtered — even if the BGW was down when the abort happened, the aborted insert never appears in the slot replay.

### 5.4 Standby Path

On a standby, there is no DML and no IPC. The BGW runs in replay-only mode:

```
Standby BGW:
  1. Create/open replication slot at replay LSN
  2. Every poll interval (~200ms):
       replay committed changes from slot
       SVSAddPoints / SVSDeletePoints
  3. Staleness bounded by poll interval
```

This is identical to the primary's crash-recovery catch-up path, gated by `RecoveryInProgress()`.

### 5.5 Undo Mechanism

#### Primary defense: IPC undo

On abort, `VamanaXactCallback(ABORT)` submits undo entries to BGW. BGW calls `SVSDeletePoints` for each externalId inserted by the aborting transaction. This provides immediate cleanup when BGW is available.

#### Safety net: WAL slot filtering

If BGW is down at abort time, the undo is deferred. On BGW restart, the slot replay only delivers committed transactions (reorder buffer filtering). The aborted INSERT never appears in the replay stream. The stale externalId in the SVS graph points to a heap TID whose xmin is aborted — MVCC visibility filtering prevents it from appearing in query results. The next VACUUM cycle detects the dead TID and submits the delete via IPC.

This two-layer approach provides immediate undo when possible and guaranteed eventual correctness always.

#### Crash before undo: worked examples

**Case 1: 3 inserts, crash before rollback (no checkpoint between)**

```
1. BEGIN
2. INSERT v1, v2, v3 → BGW applies SVSAddPoints for each (undo log has 3 entries)
3. CRASH (before ROLLBACK or COMMIT)

Recovery:
  - BGW loads last checkpoint (does NOT contain v1, v2, v3)
  - Replays slot from checkpoint LSN forward
  - Reorder buffer never delivers the uncommitted transaction
  - v1, v2, v3 are simply not in the recovered graph
  - Result: correct, no cleanup needed
```

**Case 2: 3 inserts, checkpoint occurs, then crash before rollback**

```
1. BEGIN
2. INSERT v1, v2, v3 → BGW applies SVSAddPoints (undo log has 3 entries)
3. Checkpoint fires → graph saved to disk WITH v1, v2, v3; slot advanced
4. CRASH (before ROLLBACK or COMMIT)

Recovery:
  - BGW loads checkpoint (CONTAINS v1, v2, v3)
  - Replays slot from checkpoint LSN forward
  - Reorder buffer never delivers the uncommitted transaction
  - No replay command arrives to add or remove v1, v2, v3
  - v1, v2, v3 remain in the graph BUT their heap TIDs have aborted xmin
  - MVCC filtering in vamanascan hides them from all query results
  - Next VACUUM discovers the dead TIDs and submits SVSDeletePoints via IPC
  - Result: invisible to users immediately, cleaned from graph at next VACUUM
```

### 5.6 VACUUM's Role

VACUUM is the authoritative delete-discovery mechanism, scanning the index for dead TIDs and submitting them to the BGW:

```c
vamanabulkdelete():
    for each TID in index:
        if callback(TID) says "dead":
            submit SVSDeletePoints to BGW via IPC
    return stats

vamanavacuumcleanup():
    if numDeleted > threshold:
        submit CONSOLIDATE to BGW
        submit COMPACT to BGW (if threshold exceeded)
```

The replication slot provides crash-recovery protection so deletes applied by the BGW are not lost on crash — they'll be re-discovered by the next VACUUM anyway, but the slot makes recovery faster.

### 5.7 CREATE INDEX Workflow

#### Problem: Race Between CREATE INDEX and First INSERT

The BGW keeps the SVS graph in its private process memory. After CREATE INDEX serializes the graph to disk, the BGW must load it before serving queries. The naive approach (signal BGW to reload asynchronously) introduces a race:

1. CREATE INDEX holds AccessExclusiveLock on the index relation
2. BGW receives reload signal, tries `ConditionalLockRelationOid`, fails (lock held)
3. CREATE INDEX commits, lock released
4. First INSERT arrives, BGW has not loaded the index yet
5. INSERT fails with "index not loaded for write"

#### Solution: Deterministic Load via IPC

The backend absorbs the load latency at build time by submitting a LOAD request to the BGW before returning from `vamanabuild`. The BGW loads from the save directory (no `index_open`, no lock conflict) and confirms via the IPC slot. The backend blocks until DONE.

The replication slot is created by the backend (not the BGW) immediately after serialization. This eliminates the lazy-creation gap and anchors the slot LSN to the exact point where the on-disk state is complete.

#### Full Sequence

```
Backend (vamanabuild)                          BGW main loop
========================                       ========================

1. CreateMetaPage(index)
   - writes build params to block 0

2. table_index_build_scan
   - collect vectors + TIDs into memory

3. SVSBuildDynamicIndex
   - build graph in backend process memory

4. VamanaSaveIndexToDisk(relid)
   - SVSSaveIndex → $PGDATA/vamana_indexes/<relid>/
   - VamanaSaveTidMapAtomically
   - VamanaMarkIndexSaved (metapage flag)

5. ReplicationSlotCreate("vamana_<db>_<idx>")
   - confirmed_flush = GetFlushRecPtr()
   - PG core persists slot to pg_replslot/

6. log_newpage_range (WAL-log index pages)

7. SVSFreeIndex (free backend-local graph copy)

8. VamanaWorkerSubmitLoad(relid, heapRelid,     ─── slot PENDING, latch set ───►
     dims, graph_degree, alpha, distType,
     vectorAttNum)
   - packs metadata into IPC slot
   - slotKind = VAMANA_SLOTKIND_LOAD
   - blocks on slot latch
     (heartbeat-aware, no fixed timeout)
                                                9.  Wakes from WaitLatch

                                                10. ProcessRequests():
                                                    finds LOAD slot, transitions
                                                    to PROCESSING

                                                11. VamanaWorkerProcessLoadSlot:
                                                    - Reads SVS index from
                                                      $PGDATA/vamana_indexes/<relid>/
                                                    - VamanaCacheIndex(relid, heapRelid,
                                                        dims, ..., tidMapping)
                                                    - VamanaReplicationOpen(dboid, relid)
                                                      (slot already exists from step 5)
                                                    - cache->last_replay_lsn =
                                                      GetFlushRecPtr()

                                                12. slot status = DONE
                                                ◄── latch set on backend ────────────

13. Backend wakes, sees DONE
    - returns IndexBuildResult

═══ PG core commits CREATE INDEX transaction ═══
═══ AccessExclusiveLock released ════════════════

    BGW cache is warm.
    First INSERT/SEARCH served immediately.
```

The BGW loads from the filesystem save directory (`$PGDATA/vamana_indexes/<relid>/`), not from relation pages. The relid and build parameters are passed through the IPC slot. No catalog access or relation lock required. The backend's AccessExclusiveLock protects the BGW's load: no other process can interfere with the save directory while the backend holds the lock.

#### Crash Scenarios

| Crash point | State on recovery |
|---|---|
| During steps 1–4 (before slot creation) | Transaction uncommitted. PG rolls back catalog entry. Orphaned save directory cleaned by object-access hook or next startup. |
| During steps 5–7 (after slot, before IPC) | Slot exists, save directory complete, WAL-logged pages present. BGW loads at startup via LoadAllIndexes. No data loss. |
| During steps 8–12 (IPC in flight) | Same as above: slot + save directory complete. Backend's transaction is uncommitted. PG rolls back. BGW loads cleanly from disk on next startup. |
| After step 13, before PG COMMIT | PG rolls back catalog entry. Orphaned save directory + replication slot persist. Cleaned on next DROP attempt or by startup reconciliation. |

#### BGW-Unavailable Fallback

If the BGW is not running during CREATE INDEX:

1. Steps 1–7 proceed normally (serialize + create slot)
2. Skip step 8 (no IPC submission)
3. Log WARNING: "BGW unavailable; index will be adopted at startup"
4. On BGW startup, `LoadAllIndexes` finds the index, loads from disk, opens the slot
5. First INSERT blocks on `VamanaWorkerWaitUntilAvailable` until BGW sets `workerPid` (only after `LoadAllIndexes` completes, guaranteeing the cache is warm)

### 5.8 Checkpoint and Atomicity

#### What Is a Checkpoint

A checkpoint makes the in-memory SVS graph durable to disk and marks that point as "fully processed" in the replication slot. Between checkpoints, the BGW continuously applies committed changes from the slot to the in-memory graph.

**Three states to keep consistent:**
1. In-memory SVS graph (volatile, lost on crash)
2. On-disk SVS graph (durable, updated at checkpoint)
3. Slot LSN position (durable, marks "what's on disk")

#### Checkpoint Triggers (Debounce Design)

The design follows the Redis AND-logic pattern:

```
Rule 1 (burst completion): ops >= min_ops AND quiet_for >= debounce_window
Rule 2 (safety timeout):   ops >= min_ops AND time >= max_interval

should_checkpoint = Rule 1 OR Rule 2
```

`min_ops` acts as a **filter** that prevents expensive checkpoints for trivial changes. `max_interval` is a safety net for constant-write workloads (never-quiet) that would otherwise cause unbounded WAL accumulation.

**Clean shutdown checkpoint:** When BGW receives SIGTERM, it performs a final checkpoint before exiting, advancing the slot to current WAL position. Next startup has zero replay cost.

#### Atomic Checkpoint Sequence (5 Phases)

```c
void PerformCheckpoint(VamanaCacheEntry *cache)
{
    // Phase 1: Write to temporary files
    VamanaSaveIndexToDisk(indexRel, cache->index, MAIN_FORKNUM, cache, graphTmp);
    VamanaSaveTidMap(cache->tidMapping, tidmapTmp);

    // Phase 2: Fsync temporary files (durability)
    fsync_fname(graphTmp, false);
    fsync_fname(tidmapTmp, false);

    // Phase 3: Atomic rename (crash-safe)
    durable_rename(graphTmp, cache->graphPath, LOG);
    durable_rename(tidmapTmp, cache->tidmapPath, LOG);

    // Phase 4: Fsync directory (make renames durable)
    fsync_parent_path(cache->graphPath);

    // Phase 5: Advance slot (ONLY after checkpoint fully durable)
    current_lsn = GetFlushRecPtr();
    VamanaSlotAdvance(cache->slot, current_lsn);
}
```

**Critical invariant:** Slot LSN only advances **after** `SVSSaveIndex()` succeeds.

| Phase | Purpose | Crash result |
|---|---|---|
| 1. Write temp files | Isolate writes from live files | Crash → temp incomplete, old files intact |
| 2. Fsync temp files | Ensure temp files durable | Crash → temp complete but not renamed |
| 3. Atomic rename | Make new files visible | Crash → either old OR new files exist |
| 4. Fsync directory | Make renames durable | Crash → new files guaranteed visible |
| 5. Advance slot | Mark checkpoint complete | Crash before → replay from old LSN; after → skip replay |

#### Crash Scenarios and Recovery

**Scenario 1: Crash after applying to memory, before checkpoint**
```
t1: BGW reads slot (LSN 100-200)      → 101 vectors in memory, 100 on disk, slot LSN 100
t2: CRASH
t3: Restart: Load on-disk graph       → 100 vectors
t4: Replay from slot LSN 100          → 101 vectors
Result: ✅ Correct — changes reapplied from slot
```

**Scenario 2: Crash after SVSSaveIndex, before slot advance**
```
t1: BGW applies changes (LSN 100-200) → 101 vectors in memory, 100 on disk, slot LSN 100
t2: Checkpoint: SVSSaveIndex()        → 101 vectors on disk, slot LSN still 100
t3: CRASH (before slot advance)
t4: Restart: Load on-disk graph       → 101 vectors
t5: Replay from slot LSN 100          → externalId=42 replayed again → idempotent no-op
Result: ✅ Correct — idempotency handles the duplicate
```

**Scenario 3: Successful checkpoint, then crash**
```
t1: SVSSaveIndex()                    → 101 vectors on disk, slot LSN 100
t2: pg_logical_slot_advance(200)      → slot LSN 200
t3: CRASH
t4: Restart: Load on-disk graph       → 101 vectors
t5: Replay from slot LSN 200 forward  → no changes to replay
Result: ✅ Correct — zero replay cost
```

#### Key Properties

| Property | Guarantee |
|---|---|
| **Durability** | If slot LSN = X, on-disk graph contains all changes up to X |
| **No Data Loss** | Crash recovery replays from slot LSN forward (bounded cost) |
| **Idempotency** | Safe to replay the same change multiple times |
| **Atomicity** | Either old checkpoint OR new checkpoint exists (never partial) |
| **Ordering** | Save first, advance slot second (never reverse) |
| **Search Latency** | Paused during checkpoint |
| **Insert/Delete Latency** | Paused during checkpoint (same window) |
| **Clean Shutdown** | Zero replay cost (slot advanced to current LSN) |

### 5.9 WAL and Replication Slot Internals

#### What Is WAL

WAL is PostgreSQL's transaction log — a continuous, append-only stream of records that describes every change made to the database. Changes are written to WAL **before** they're written to data pages, ensuring durability and enabling crash recovery.

#### What Is LSN

**LSN** (Log Sequence Number) is a 64-bit unsigned integer representing a byte offset (position) in the WAL stream. It tells you *where* to find something in WAL, not what it contains. LSNs are displayed as `XX/YYYYYYYY` (segment number / byte offset within segment).

#### How the BGW Uses WAL

The BGW does not write WAL — it reads from a logical replication slot. Backends' DML writes normal PostgreSQL WAL. The BGW polls the slot, which delivers only committed changes (reorder buffer filters aborted transactions).

```
Backend commits transaction:
   ↓
PostgreSQL writes INSERT + COMMIT records to WAL
   ↓
fsync() — now durable on disk
   ↓
BGW polls slot — receives the committed INSERT
   ↓
SVSAddPoints applied to in-memory graph
```

#### restart_lsn vs confirmed_flush_lsn

Logical decoding encounters transactions that span multiple WAL records. The reorder buffer buffers changes until COMMIT is seen, then delivers all changes atomically. On restart, the slot must start reading from the BEGIN of the oldest buffered transaction — not from the last delivered position — to reconstruct transaction state. This is why `restart_lsn` is earlier than `confirmed_flush_lsn`.

**What we control:**
- When to call `pg_logical_slot_advance()` (checkpoint timing)
- What LSN to pass (current WAL flush position)
- Ensuring idempotency for duplicate replay

**What PostgreSQL controls:**
- Calculating `restart_lsn` based on reorder buffer state
- Delivering only committed, complete transactions
- Filtering aborted transactions

We never directly read or set `restart_lsn` — it's managed entirely by PostgreSQL's logical decoding infrastructure.

#### WAL Retention Implications

PostgreSQL retains WAL from `restart_lsn` forward (not `confirmed_flush_lsn`). Causes of large lag:

1. **Long-running transactions** — `restart_lsn` anchored at BEGIN for duration
2. **BGW down** — `confirmed_flush_lsn` not advancing, WAL accumulates
3. **Infrequent checkpoints** — `confirmed_flush_lsn` advances only at checkpoint

The `svs.max_slot_wal_size` GUC is the safety valve: if lag exceeds the threshold, drop slot and rebuild from heap.

| LSN Type | Managed by | When it advances | Affects WAL retention |
|---|---|---|---|
| `restart_lsn` | PostgreSQL | All buffered transactions delivered | Yes |
| `confirmed_flush_lsn` | SVS extension (at checkpoint) | `pg_logical_slot_advance()` call | No |

---

## 6. GUC Parameters

### 6.1 Runtime Query Parameters

| GUC | Type | Default | Range | Scope | Description |
|---|---|---|---|---|---|
| `svs.search_window_size` | int | 100 | 10–10000 | `PGC_USERSET` | Search window (L) for index scans. Higher values improve recall at the cost of latency. |
| `svs.search_num_threads` | int | 0 | 0–1024 | `PGC_USERSET` | Threads SVS uses for search. `0` = auto (`nproc-1`). Lower values reduce oversubscription under concurrent load. |

### 6.2 Background Worker Parameters

`svs.worker_database` and `svs.worker_restart_time` require a server restart (set before starting PostgreSQL or changed with restart). The timeout GUCs can be updated at runtime via `SIGHUP`.

| GUC | Type | Default | Range | Scope | Description |
|---|---|---|---|---|---|
| `svs.worker_database` | string | `"postgres"` | — | `PGC_POSTMASTER` | Database the background worker connects to. Must match the database where Vamana indexes are created. |
| `svs.worker_restart_time` | int | 5 | -1–300 | `PGC_POSTMASTER` | Seconds before a crashed worker is restarted. `-1` = `BGW_NEVER_RESTART`. |
| `svs.worker_startup_timeout_ms` | int | 60000 | 1000–300000 | `PGC_SIGHUP` | Milliseconds a backend waits for the worker to finish startup before throwing an error. Startup can be slow when many large indexes are deserialized from disk. |
| `svs.worker_timeout_ms` | int | 5000 | 100–60000 | `PGC_SIGHUP` | Milliseconds a backend waits for the worker to respond to an IPC request (search or write) before throwing an error. |
| `svs.max_batch_size` | int | 0 | 0–1000 | `PGC_SIGHUP` | Maximum queries per SVS batch search call. `0` = `MaxBackends`. |
| `svs.compact_threshold_pct` | int | 10 | 0–100 | `PGC_USERSET` | Percent-deleted threshold that triggers SVS compact during VACUUM cleanup. `0` = compact on every VACUUM with pending deletes; `100` = disable compact (consolidate still runs). |
| `svs.max_slot_wal_size` | string | `10GB` | — | `PGC_SIGHUP` | Maximum WAL retained by the replication slot. If exceeded, the slot is dropped and the index is rebuilt from the heap. |
| `svs.checkpoint_debounce_window` | int | 300 | — | `PGC_SIGHUP` | Seconds of write inactivity required after a burst before a checkpoint is triggered (AND-logic with `checkpoint_min_ops`). |
| `svs.checkpoint_max_interval` | int | 3600 | — | `PGC_SIGHUP` | Maximum seconds between checkpoints; safety net for constant-write workloads that never go quiet. |
| `svs.checkpoint_min_ops` | int | 10000 | — | `PGC_SIGHUP` | Minimum write operations required before any checkpoint rule fires. Prevents expensive checkpoints for trivial changes. |
| `svs.checkpoint_operations` | int | -1 | — | `PGC_SIGHUP` | Legacy op-count checkpoint trigger. `-1` = off. Setting a positive value activates simple mode (overrides debounce logic). |
| `svs.checkpoint_interval` | int | -1 | — | `PGC_SIGHUP` | Legacy time-based checkpoint trigger in seconds. `-1` = off. Setting a positive value activates simple mode. |

### 6.3 Index Creation Parameters

Specified in the `WITH (...)` clause of `CREATE INDEX`.

| Parameter | Type | Default | Range | Description |
|---|---|---|---|---|
| `graph_degree` | int | 64 | 16–256 | Maximum graph connections per node (R parameter). |
| `alpha` | int | -1 | -1–200 | Pruning parameter scaled by 100 (`120` = α 1.20). `-1` uses SVS library default. |
| `build_window_size` | int | -1 | -1–1000 | Build window size (L parameter). `-1` = `2 × graph_degree`. |
| `search_window_size` | int | 100 | 10–10000 | Search window during build and initial queries. |
| `use_search_history` | bool | `true` | — | Maintain the visited-node set during search. |
| `compression_type` | int | 0 | 0–2 | `0` = none, `1` = LeanVec, `2` = LVQ. |
| `compression_primary` | int | 8 | -8–8 | LeanVec primary quantization: `4`=UINT4, `-4`=INT4, `8`=UINT8, `-8`=INT8. |
| `compression_secondary` | int | 8 | -8–8 | LeanVec secondary quantization (same values as primary). |
| `leanvec_dims` | int | -1 | -1–2000 | Reduced dimensions for LeanVec. `-1` = `dimensions / 2`. |

---

## 7. Integration Points

### 7.1 Build System (Makefile)

The extension is built with `pgxs` and requires the Intel SVS C API library:

```makefile
SVS_INSTALL ?= svs_install_public
# Requires: $(SVS_INSTALL)/lib/libsvs_c_api.so
```

Compiler flags for SIMD optimization:
```
-march=native -ftree-vectorize -fassociative-math -fno-signed-zeros -fno-trapping-math
```

> **Note:** `-march=native` is conditionally disabled on ARM Mac, PowerPC, and RISC-V64 (see `Makefile:17–33`). On those platforms `OPTFLAGS` is empty and only the remaining flags are applied.

### 7.2 Extension Control File (`svs.control`)

```
comment = 'SVS Vamana index access method for pgvector'
default_version = '0.1.0'
requires = 'vector'
module_pathname = '$libdir/svs'
```

### 7.3 SQL Registration

```sql
CREATE FUNCTION vamanahandler(internal) RETURNS index_am_handler ...;
CREATE ACCESS METHOD vamana TYPE INDEX HANDLER vamanahandler;
```

Operator classes for `vector` and `halfvec` are registered as shown in Section 4.6.

Users install the extension with:

```sql
CREATE EXTENSION svs;  -- also installs the 'vector' dependency automatically
```

### 7.4 Loading via shared_preload_libraries

The background worker is registered automatically when the extension is loaded via `shared_preload_libraries`. No additional GUC is needed to enable it.

```
# postgresql.conf
shared_preload_libraries = 'vector,svs'
svs.worker_database = 'mydb'          # default: 'postgres'
svs.worker_restart_time = 5           # default: 5 seconds
```

`vector` must appear before `svs` because `svs` depends on it.

---

## 8. Performance Considerations

### 8.1 Optimization Strategies
1. **AVX-512 SIMD:** SVS automatically uses Intel hardware optimizations when compiled with `-march=native`
2. **Compression:** Enable LVQ (`compression_type=2`) for memory-constrained systems; LeanVec (`compression_type=1`) for two-level quantization
3. **Thread count:** Tune `svs.search_num_threads` to match workload; `0` auto-selects `nproc-1`
4. **Background worker:** Load the extension via `shared_preload_libraries` to amortize index load cost across all backends; the worker is always-on when loaded this way
5. **Incremental writes:** Inserts update the graph incrementally; periodic `REINDEX` restores optimal graph quality after many mutations

### 8.2 Write Considerations

Inserts are applied incrementally via `SVSAddPoints` and are immediately searchable. Deletes are applied during VACUUM via `SVSDeletePoints` with graph consolidation. For write-heavy workloads:
- Writes are serialized per-index inside the BGW via a per-index LWLock (`VamanaIndexLockSlot`); high-throughput inserts may experience contention
- The write lock is scoped by relation OID — concurrent writes to different indexes never serialize against each other
- Checkpoints run on the BGW main thread and block both searches and writes for their duration. This is required because `MutableVamanaIndex::save()` is not `const`: it calls `consolidate()` then `compact()` before writing, mutating shared graph state. Concurrent save + search is an unconditional data race. INSERT, DELETE, and SEARCH requests queue on their IPC slot latches and are processed once the checkpoint completes
- Periodic `REINDEX CONCURRENTLY` produces a fresh, optimally-constructed graph after many incremental mutations
- All writes (INSERT, DELETE, VACUUM) go through the background worker; the worker is the single owner of the live in-memory index, so all backends see a consistent view after the worker processes each slot

### 8.3 Memory Overhead

The TID mapping array is sized by `tidMappingCapacity`, not by the live vector count `numVectors`. After deletions, the capacity grows monotonically until `SVSCompact` reclaims the deleted slots. In workloads with high delete churn and infrequent compaction, the TID mapping and its on-disk sidecar can be significantly larger than the live vector count alone would suggest. Lowering `svs.compact_threshold_pct` reduces this overhead at the cost of more frequent compaction during VACUUM.

In addition to the graph edges and stored vectors, the SVS dynamic index maintains a small amount of per-vector bookkeeping (delete flags, insertion metadata). This overhead is small relative to the graph itself but grows linearly with `tidMappingCapacity`.

