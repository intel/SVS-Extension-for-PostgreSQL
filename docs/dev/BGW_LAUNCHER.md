# Background Worker Launcher and Per-Database Worker Model

## Table of Contents

1. [Overview](#1-overview)
2. [Process Model](#2-process-model)
3. [The Configuration Catalog](#3-the-configuration-catalog)
4. [Shared Memory Layout](#4-shared-memory-layout)
5. [Enabling a Database: The Reservation Handshake](#5-enabling-a-database-the-reservation-handshake)
6. [Launcher Behavior](#6-launcher-behavior)
7. [Worker Crash Detection and Restart](#7-worker-crash-detection-and-restart)
8. [Worker Lifecycle: Startup and Demand-Driven Loading](#8-worker-lifecycle-startup-and-demand-driven-loading)
9. [Drain-and-Stop: Pause, Restart, and Clean Shutdown](#9-drain-and-stop-pause-restart-and-clean-shutdown)
10. [Pause vs. Permanent Removal](#10-pause-vs-permanent-removal)
11. [Gating CREATE INDEX on Configuration State](#11-gating-create-index-on-configuration-state)
12. [Observability](#12-observability)
13. [Configuration Parameters](#13-configuration-parameters)
14. [Standby and Replication Behavior](#14-standby-and-replication-behavior)

---

## 1. Overview

A Vamana index is not self-contained in the way a B-tree or an HNSW index is. Its graph lives in a background worker's private memory, is served to backends over shared-memory IPC, and is persisted through a checkpoint-and-replication-slot mechanism rather than through ordinary buffer-managed relation pages. Every database that hosts Vamana indexes therefore needs a background worker dedicated to it.

This document describes the mechanism that manages those workers: a single supervisor process (the *launcher*) that starts, stops, restarts, and tracks one *per-database worker* for each database an operator has enabled for Vamana. The design lets an operator enable Vamana for a new database, pause it, restart its worker, or remove it permanently, all by changing rows in a configuration table, with no server restart and no edits to `postgresql.conf`.

The model replaces an earlier single-worker design in which one statically registered worker served exactly one database named by a configuration parameter. That earlier model gave a hard error for Vamana indexes in any other database, and changing the target database required editing the configuration file and restarting the server.

---

## 2. Process Model

There is exactly one statically registered background worker: the launcher. It is registered when the extension is loaded into the postmaster, before shared memory is allocated, because PostgreSQL requires all static background workers to be registered at that point. Everything else is dynamic.

```
postmaster
  └── launcher              (static; connects to the launcher's home database)
        reads:   vamana_databases catalog table
        spawns:  one dynamic worker per enabled database
        └── worker for "mydb"
        └── worker for "appdb"
        └── ...
```

The launcher is a supervisor, not a data-plane process. It never serves index queries, never holds graph state, and never allocates shared memory. Its single responsibility is to keep the set of running per-database workers in agreement with the set of enabled databases in the configuration catalog, and to bring workers back when they die.

Each per-database worker is bound to its database for its whole lifetime. It owns the in-memory SVS graph state for every Vamana index in that database, processes IPC requests from backends (search, insert, delete, maintenance), owns that database's replication slot, and performs the periodic checkpoints that persist graph state to disk. Nothing about a worker's data-plane responsibilities changed with the move to the launcher model; what changed is that there is now one worker per database, spawned on demand, rather than one worker for the whole cluster.

---

## 3. The Configuration Catalog

Enablement is expressed as rows in a table named `vamana_databases`. The table lives in a single database: the launcher's home database (by default, `postgres`). The launcher connects there to read the table. It does not need to connect to a target database until it actually spawns a worker for that database.

Conceptually the table records, per database:

- The database name. This is the primary key. The table is keyed by name, not by database OID, deliberately. Storing an OID would duplicate state that is always derivable from the name, would create an ongoing obligation to keep the two in sync, and would open an OID-reuse hazard in which dropping and recreating a database could silently bind a worker to the wrong database. The launcher resolves each name to a live OID on every scan, so a worker always binds to whatever database currently bears that name.
- Whether the database is currently enabled. Disabling is a reversible pause, not a removal (see [Pause vs. Permanent Removal](#10-pause-vs-permanent-removal)).
- A set of reserved per-database resource columns (graph memory, total memory, search thread count). These exist in the schema so the table's shape is stable, but nothing reads or enforces them yet; they are placeholders for a future resource-management phase. A `NULL` value means "use the cluster-wide default."

Two triggers are attached to this table. They do different jobs and both fire on the same change:

- A statement-level trigger sends an asynchronous notification on a dedicated channel whenever the table changes. This is what wakes the launcher promptly rather than making it wait for its next periodic poll.
- A row-level trigger participates in the synchronous slot-reservation handshake described in [Section 5](#5-enabling-a-database-the-reservation-handshake). It fires per affected row because reserving a specific database's shared-memory slot requires per-row data (the database name), which the statement-level trigger never sees.

Wholesale truncation of the table is blocked by revoking the truncate privilege from `PUBLIC`. Truncation would bypass the per-row safety checks that guard removal, and there is no legitimate operational reason to wipe this low-cardinality control table in one statement: every lifecycle operation already has a purpose-built primitive. The table owner retains the privilege, which is sufficient.

---

## 4. Shared Memory Layout

Backends and workers coordinate through a fixed-size array of per-database control structures in shared memory, sized at postmaster startup by a postmaster-level parameter (`svs.max_databases`). The array cannot grow at runtime; PostgreSQL has no native mechanism for growing a shared-memory region after allocation. Exhausting it is handled explicitly (see [Section 5](#5-enabling-a-database-the-reservation-handshake)).

The layout separates two concerns that used to share one variable-length structure:

- A small, fixed-stride control structure per database. This holds the database OID that identifies the slot, the worker's process ID (its readiness claim), an atomic index counter, the worker's latch and heartbeat, and the launcher's own crash-backoff state. Because each entry is fixed size, these entries form the array that backends scan.
- Separate flat buffers holding the large backend-IPC region (the per-backend request slots and their query-vector, result-TID, and distance areas). These are sized by `svs.max_databases` multiplied by the per-database backend-scaled size. Each control entry points into its database's region of these buffers, stitched together once at shared-memory startup.

This follows PostgreSQL's own idiom for "N entities, each needing a large per-backend-scaled attachment" rather than trying to make an array of variable-length structures, which C does not allow.

A backend finds its database's entry by scanning the array for a matching database OID. The scan is linear in the number of active databases, which is expected to be small.

### Ownership discipline

A single control entry is written by two different processes, so ownership is made structural rather than left to convention:

- The **worker** owns its liveness fields: its process ID and heartbeat. It publishes its process ID when it is ready to serve, and clears it on exit.
- The **launcher** owns the slot's identity (the database OID) and a grouped sub-structure holding that database's crash-backoff state. The launcher never writes worker liveness fields, and the worker never writes launcher backoff fields.
- The **index counter** is an atomic, maintained by whichever backend runs a `CREATE INDEX` or `DROP INDEX`, independent of whether the worker is running. It supports both the removal safety check ([Section 10](#10-pause-vs-permanent-removal)) and observability ([Section 12](#12-observability)); it is one field with two consumers, not two counters.

Grouping the backoff state into its own named sub-structure, rather than scattering flat fields next to the worker-owned IPC fields, makes the "one struct, two owners, two locking disciplines" boundary visible in the type itself instead of only in prose a future reader has to reconstruct.

An array-wide lock guards slot identity (finding a slot by OID, reserving a new slot) and the launcher's backoff fields. Incrementing or decrementing the index counter does not take that lock; it is a plain atomic operation, because that counter is touched on every `CREATE INDEX` and `DROP INDEX` across every database and must not serialize on a single administrative lock.

---

## 5. Enabling a Database: The Reservation Handshake

Enabling a database has to satisfy a subtle timing requirement. A backend that runs `CREATE INDEX ... USING vamana` needs to distinguish three states of the current database:

1. Not configured for Vamana at all (or configured but disabled). This must fail immediately.
2. Configured and enabled, but the worker process has not finished starting yet. This is a legitimate brief race, and the backend should wait, bounded by the startup timeout.
3. Configured, enabled, and the worker is running. Proceed normally.

Distinguishing state 1 from state 2 requires that a database's shared-memory slot be *reserved* (its OID written, its worker process ID left at zero) the instant the enabling transaction becomes visible, not merely when the worker eventually starts. If reservation were left to the launcher's asynchronous reaction, there would be a window between the enabling commit and the launcher's write in which a `CREATE INDEX` would see "no slot" and fail incorrectly, even though the row genuinely said the database was enabled.

The design closes this window by reserving the slot inside the enabling transaction's own commit, through two independent paths that together cover both live enablement and server restart:

### Live enablement: reservation at commit

When an operator enables a database, the row-level trigger appends the affected row to a small backend-local list held in transaction-scoped memory. A transaction callback, registered exactly once per backend, drains that list during pre-commit, before the commit record is written and before the row becomes visible to any other backend. For each enabled entry it reserves the database's shared-memory slot under the array lock.

Several details make this safe:

- The callback is registered once per backend, guarded by a static flag, from the extension's own initialization path. The trigger itself registers nothing. Registering a callback per row would leak a never-cleaned entry on every statement for the life of the session.
- Taking the array lock and writing shared memory during pre-commit is a sanctioned pattern; PostgreSQL's own notification machinery reserves a queue slot under a lock at exactly this stage of commit.
- Raising an error from the callback is safe here, because pre-commit runs before the transaction's point of no return. An error routes cleanly into abort, which releases held locks.
- The callback tracks the *set* of slots it reserved this transaction, in transaction-scoped memory. If a later pre-commit step aborts the transaction, an abort handler releases exactly those reservations, so a transaction that never commits leaves no orphaned slots. A single callback handles pre-commit, commit, and abort by switching on the event, rather than registering separate handlers. A crash between reservation and commit needs no handling: shared memory does not survive a crash, so the reservation and the crash vanish together.
- If the array is already full, the callback fails the enabling statement outright with an actionable error, rather than silently leaving a row enabled with no slot behind it, or writing past the array. This reuses the callback's existing error path; it is not a new mechanism.

By the time the enabling statement returns to the operator, the slot exists. A later `CREATE INDEX` can therefore only ever land in state 2 or state 3, never state 1.

### Server restart: the launcher as config materializer

The commit-time path covers enablement while the server is running, but it does not cover a server restart. After a restart, shared memory is wiped and there is no enabling transaction to re-run for databases that were already enabled long ago. Without a second path, a `CREATE INDEX` in a long-enabled database, issued in the window before that database's worker starts up and reserves its own slot, would see "no slot" and fail incorrectly.

The launcher closes this by *materializing configuration* at its own startup, before it spawns anything:

1. It scans `vamana_databases` and reserves a slot for every enabled row (OID set, worker process ID left at zero).
2. It publishes a header flag indicating the initial scan is complete.
3. Only then does it begin spawning workers.

The "no slot means not configured" invariant is authoritative only after that flag is set. Before it is set, a backend cannot yet distinguish a valid-but-not-yet-materialized database from an unconfigured one, so the configuration check returns without erroring during that brief pre-publish window rather than risking a false hard error.

The commit-time reservation and the launcher's startup materialization are temporally disjoint (one happens during live operation, the other only at launcher startup), and reservation is idempotent, so the two never conflict. The worker also reserves its own slot at startup as a final safety net.

---

## 6. Launcher Behavior

The launcher runs a single reconcile loop. Every wake, regardless of what woke it, performs one pass that reconciles the set of running workers against the set of enabled databases. There is deliberately no separate "handle this specific event" path.

A pass proceeds in a fixed order:

1. **Reset the latch and check for interrupts.** The latch is reset before the catalog scan, so that a change arriving during the scan re-arms the latch and earns another pass, rather than being lost to a reset that races the change.
2. **Drain pending notifications, outside any transaction.** There is a single channel with an empty payload; any notification simply means "the table changed, re-diff." Every operator action, including an on-demand restart, is a catalog change observed through the diff rather than a distinct payload verb (see [Section 9](#9-drain-and-stop-pause-restart-and-clean-shutdown)). Draining must happen outside a transaction, and must be done in a mode that does not attempt to flush to a client connection, because the launcher has no client; flushing would error and crash the launcher on every catalog change. Draining is also necessary in its own right, to advance the notification queue and avoid a slow resource leak on a busy table.
3. **Scan the enabled databases, inside a transaction.** Any catalog access from a background worker must run inside an open transaction; otherwise it crashes for lack of a resource owner and snapshot. The scan captures each enabled database's name during the scan and carries it out in a small structure, so that the spawn logic that runs after the transaction commits never re-enters the catalog. Names are resolved to live OIDs tolerantly: a name that resolves to nothing (for example, a database that was dropped) is skipped and logged, never deleted from the table, because the launcher does not own the operator's configuration.
4. **Reconcile liveness and spawn what is missing.** For each database that should be running, the launcher consults its own bookkeeping (see below) to decide whether a worker is live or a spawn is already in flight, applies the crash-backoff gate ([Section 7](#7-worker-crash-detection-and-restart)), and spawns any worker that is missing and past its backoff.
5. **Sleep until the next wake.** The sleep interval is the minimum, over all databases currently backing off, of each one's remaining backoff time, folded against a long fallback interval and clamped to a small floor. Computing the wake time in the same pass that made the skip decision keeps "skip this database now" and "wake in time to retry it" as one fact about one database, rather than two loops that can drift apart.

### The handle ledger

To decide whether a worker needs spawning, the launcher does **not** read the slot's worker-process-ID field. That field is written by the worker itself only once it has fully started, and is zero during the register-fork-connect window. A pass that re-entered during that window and treated a zero process ID as "no worker" would register a *second* worker for the same database; two workers sharing one latch and one replication slot would corrupt state.

Instead the launcher keeps its own local ledger, keyed by database OID, of the handles returned when it registered each worker. The handle's status (started, stopped) is the authoritative signal for spawn and liveness decisions. This mirrors PostgreSQL's own logical-replication launcher, which tracks in-flight starts rather than inferring them.

The two signals are kept distinct on purpose: the slot's worker-process-ID is the *worker's* readiness claim, read by backends; the handle ledger is the *launcher's* spawn bookkeeping, read only for spawn decisions. The ledger is launcher-local and is lost if the launcher itself restarts, which is fine: on restart the launcher re-materializes from the catalog, and already-running workers show a nonzero process ID in their slots.

Both the ledger entries and the handles they point to must be allocated in a context that lives for the launcher's whole process lifetime, not in the per-pass scratch context that is freed at the end of each reconcile pass. A handle allocated in the scratch context would dangle after that context is freed, and the next wake would crash when it polled the handle's status.

---

## 7. Worker Crash Detection and Restart

Per-database workers are registered so that the launcher, not the postmaster, controls their restart. Two registration settings achieve this:

- The worker is registered to **never** be auto-restarted by the postmaster. On a crash, the postmaster forgets the worker immediately, with no restart timer.
- The worker is registered to **notify the launcher** on any status change, including death, by signaling the launcher's process. This is the same mechanism PostgreSQL's own logical-replication launcher uses for its apply workers.

The result is that a crash is detected near-instantly through the signal, not bounded by the poll interval, and the launcher decides when, whether, and how to bring the worker back.

### Reconcile, don't react

The launcher does **not** treat the death signal as "one worker died, go find it." The latch that the signal sets is binary and coalescing: if several workers die within one wake window, the launcher sees a single set latch, not one per death. A handler that counted signals would miss deaths precisely in the crash-loop scenarios this mechanism most needs to handle.

Instead, every reconcile pass re-derives each tracked worker's liveness from its handle status and reconciles to the desired state. Missed-death bugs cannot exist by construction, because the pass never depends on how many signals arrived. Ground truth is the handle status rather than the slot's process-ID field, so that a worker killed before it ever published its process ID is still correctly seen as stopped.

### Escalating backoff

A worker that crash-loops (from a corrupted index, an out-of-memory condition, and so on) must not be respawned every second forever. The launcher applies an exponential backoff with a hard ceiling: the delay before respawning doubles with each consecutive failure, capped at a fixed maximum. This is a deliberate divergence from PostgreSQL's own launcher, which uses a fixed retry interval with no escalation; the divergence is intentional and recorded so that a future maintainer comparing against core does not "correct" it back to a fixed interval.

Two aspects of the backoff are load-bearing:

- **The backoff state lives in shared memory, on the same per-database slot, not in the launcher's local memory.** The whole purpose of crash-loop protection is to survive the thing that would otherwise defeat it: a process restart that zeroes the counter. The launcher is itself natively restarted by the postmaster on its own crash. If the backoff counter were launcher-local, restarting the launcher would reset every counter to zero, and a crash-looping database would immediately be respawned at full speed, defeating the protection. Storing the counter in shared memory (grouped into the slot's launcher-owned sub-structure) gives it the lifetime the feature requires. Corruption tolerance is trivial: a launcher crash mid-update yields at worst a stale count and one mistimed respawn, self-correcting on the next crash.
- **The failure counter resets on dwell, not on start.** The counter is reset to zero only when a worker that has died had previously stayed alive for at least the ceiling interval. Resetting on successful start would be wrong: a worker that publishes its process ID and then crashes on its first index access would reset the counter every cycle, so escalation would never engage and the tight crash-loop would return. "Started" is not "recovered"; only "stayed up long enough" is.

A database that disappears from the scan (for example, one that was dropped) has its backoff state dropped entirely and accrues no failures. A connect-time failure against a since-dropped database must not be mistaken for a crash-loop; the scan-drop takes precedence over the failure counter.

The whole restart flow:

```
worker for "mydb" crashes
        |
        v
postmaster forgets it (never-restart) and signals the launcher
        |
        v
launcher's next reconcile pass re-derives liveness from handle status,
sees "mydb" stopped, applies dwell-based reset or increments failures
        |
        +-- past backoff threshold?
        |     yes -> register a fresh worker for "mydb"; stamp attempt time
        |     no  -> skip this pass; fold remaining backoff into next wake time
        v
new worker starts for "mydb", fresh, with no memory of the crash
```

---

## 8. Worker Lifecycle: Startup and Demand-Driven Loading

A per-database worker is spawned with its database OID as its argument. On startup it connects to that database, publishes its process ID immediately to unblock waiting backends, and then serves requests.

Loading is **demand-driven**. The worker does not eagerly load every index in the database at startup. The first request for a given index loads that index on demand; subsequent requests find it cached. This replaced an earlier eager-preload model in which backends stayed blocked until every index in the database had been loaded before the worker declared itself available. Under demand-driven loading, startup cost no longer scales with the number or size of indexes; a worker becomes available as soon as it connects, and pays per-index load cost lazily on first use.

A corollary is that a dropped cache entry (for example, one evicted because a bounded reload queue overflowed) is recovered exactly like any other cache miss: the next request for it loads it. There is no separate full-reload path.

### Explicit warm-up

Removing eager preload means there is otherwise no way to get a hot cache without waiting on real query traffic. Benchmark harnesses and operators performing a planned restart both need to force a warm cache deliberately, at a time they control. Two SQL-callable functions provide this: one warms a single named index, and one enumerates and warms every Vamana index in the current database. They are thin wrappers over the same on-demand loading primitive the first real request would use. Nothing calls them automatically; they are purely opt-in, so that warm-up cost is attributed to a load or optimize phase rather than to first-query latency.

---

## 9. Drain-and-Stop: Pause, Restart, and Clean Shutdown

Stopping a worker cleanly is not the same as terminating it. A Vamana worker persists graph state through checkpoints that also advance its replication slot's confirmed-flush position. If a worker simply exited on termination without a final checkpoint, its replication slot would keep pinning write-ahead log at wherever the last debounced checkpoint left it, and that log would accumulate for as long as the worker stayed down.

The worker therefore has a single **drain-and-stop** shutdown routine, shared by every path that stops a worker on purpose:

1. Stop accepting new backend IPC requests. Requests already queued in shared-memory slots are still serviced; the drain does not abandon a backend mid-request.
2. For every cached index, run a checkpoint: flush the graph to disk and advance the replication slot's confirmed-flush position to the current log position.
3. Exit.

After this, the on-disk state is current and the replication slot is idle and caught up, with the same footprint as any harmless inactive slot rather than an unboundedly growing one.

Two operator-facing paths invoke this same routine:

- **Pause**, triggered by disabling a database. The launcher signals that database's worker to drain and stop, then does not respawn it because the database is no longer in the enabled set.
- **Explicit restart**, triggered by a dedicated function. This lets an operator bounce one database's worker on demand, for example to force a clean checkpoint and slot advance right now rather than waiting for the debounced checkpoint policy. The restart function bumps that database's `restart_generation` column; the launcher observes the increment through the same reconcile diff it uses for every other catalog change, rather than a distinct notification verb. On seeing a generation newer than the running worker's, the launcher runs a defined shutdown-then-respawn sequence for that one worker: signal it to drain and stop, wait for it to exit, re-read its row, and respawn it as a normal start. Because the drain always checkpoints first, the restarted worker comes back to current on-disk state and an idle slot, with nothing to replay.

Explicit restart is a separate primitive from toggling enablement off and on, and operators are directed to use it rather than the toggle, for two reasons that hold regardless of shutdown safety:

- Disabling is the "take this database offline" signal. Reusing it as a restart conflates two different operator intents.
- Two enablement updates issued back to back in one transaction never produce an intermediate state the launcher can observe, because the launcher only ever sees committed state; it would see the final "enabled" value and do nothing.

Enablement changes, existence changes, and restart-generation bumps all go through the same reconcile diff; the launcher infers each action by comparing committed catalog state against what it is currently running, never from a notification payload.

---

## 10. Pause vs. Permanent Removal

Disabling a database and removing it are different operations with different, well-defined effects. Conflating them is a real hazard, because an operator reasoning about "is it safe to leave this database like this" needs to know exactly what survives.

| | Pause (disable) | Permanent removal (teardown, then delete row) |
|---|---|---|
| Worker process | Stopped | Stopped |
| On-disk save directory | Kept | Deleted |
| Replication slot | Kept, idle, caught up | Dropped |
| Catalog row | Kept | Removed |
| Resumable? | Yes: re-enable and the worker resumes | No: indexes must be rebuilt |

### Pause

Disabling means "stop serving this database for now, but I may come back": a maintenance window, a cost-driven scale-down, a database that goes quiet on weekends. The launcher drains and stops the worker (per [Section 9](#9-drain-and-stop-pause-restart-and-clean-shutdown)) and does not respawn it. At rest, indefinitely, there is no worker process; the on-disk saves are present and current; the replication slot is present, inactive, and caught up. Nothing accumulates, because no worker means no path to generate write-ahead log against these indexes: any write attempt fails at the worker-availability check.

Re-enabling repeats the normal spawn path. The worker reconnects, loads each index on demand from its current on-disk save, and finds its replication slot idle at the checkpoint position, so there is little or nothing to replay. The pause window can be arbitrarily long without risking a forced rebuild, precisely because the drain checkpointed before exiting.

Pausing does not make queries or writes queue quietly. A backend touching a Vamana index in a paused database gets the existing bounded-wait-then-error behavior, because the worker will not start until re-enabled. Pausing means writes fail loudly and promptly, not that they wait.

Nothing ever escalates a pause into removal. Disabling never times out into deletion; a long-paused database stays exactly paused until an operator acts.

### Permanent removal

Permanent removal means "I am done with Vamana in this database." It is a deliberate, two-step operator action, and it is deliberately not a single cross-database call:

1. **In the target database:** a teardown function drops every Vamana index in that database. Each drop fires the existing object-access hook that deletes the index's on-disk save directory and drops its replication slot, exactly as a manual drop of each index would. The teardown function reuses the same index-enumeration the worker uses; it adds no new cleanup logic, only automation of what an operator would otherwise do index by index.
2. **In the launcher's database:** the operator removes the catalog row, so the launcher stops running a worker for that database.

The two steps run in the databases they actually affect. Cross-database DDL is not available in PostgreSQL without a bridging extension, and having a function quietly reach across databases would add a dependency and a privilege surface no other part of this design needs. Each step also has an honest standalone meaning.

The teardown function runs as the calling operator, not with elevated privilege. Dropping an index the caller does not own is correctly refused by PostgreSQL's ownership model, and overriding that would let a caller drop indexes they have no business dropping. To avoid aborting the whole operation on the first index the caller cannot drop, each drop runs in its own subtransaction: on failure it rolls back that one subtransaction and continues, and the function reports a summary of which indexes were dropped and which were skipped and why. This is the same subtransaction primitive that a PL/pgSQL exception block is built on, and the same one this codebase already uses to isolate one replayed change per subtransaction.

### Removal safety: rejecting the steps in the wrong order

Removing the catalog row while Vamana indexes still exist in that database would orphan their on-disk saves and replication slots, with no catalog row pointing at them. This is rejected synchronously.

The difficulty is that the check must run in a trigger on the catalog table, which lives in the launcher's database, but the fact being checked ("does that database still have Vamana indexes?") lives in the target database's own catalogs, which are not reachable by cross-database query. The design sidesteps this entirely: shared memory is process-wide, not per-database. The per-database index counter on the shared-memory slot ([Section 4](#4-shared-memory-layout)) is maintained by whichever backend runs `CREATE INDEX` or `DROP INDEX`, regardless of whether the worker is running. A before-delete trigger resolves the row's name to a database OID (the database registry is a shared catalog, readable from any database), finds that OID's slot, reads the counter, and rejects the delete with an actionable hint if the counter is nonzero. The check is thus independent of the launcher, of whether a worker is running, and of any cross-database machinery.

Because the trigger fires before commit, "delete before teardown" is a rejected statement, not a runtime scenario the launcher ever has to handle: that delete never commits and never reaches the reconcile diff. The worker, the replication slots, and the on-disk state are left exactly as if the statement had not been run.

### Forgetting to remove the row

If an operator runs teardown but forgets to remove the row, the result is safe, not a phantom. The real cleanup already happened: no save directory, no slot, no index. What remains is a catalog row for a database with zero Vamana indexes, so the launcher keeps running an idle worker. That worker is harmless but wasteful: it holds one worker-process slot and one array slot, finds zero indexes to serve, and has nothing to checkpoint or replicate.

This is made visible rather than silent: a worker whose index enumeration returns zero logs a one-time hint suggesting the row be removed, and the observability view ([Section 12](#12-observability)) reports the zero index count directly. The launcher deliberately does not auto-remove the row when the count hits zero, because a database with zero indexes right now may simply be between index creations, and silently deleting an operator's configuration row based on inferred state would be a worse surprise than one idle worker.

---

## 11. Gating CREATE INDEX on Configuration State

`CREATE INDEX ... USING vamana` must fail immediately, with a clear error, when the current database is not enabled for Vamana. It must not build the index, serialize it to disk, and only then discover there is nowhere to serve it from. The check therefore runs *before* the heap scan and SVS build begin, not after.

The check reads the per-database shared-memory slot and distinguishes the three states from [Section 5](#5-enabling-a-database-the-reservation-handshake):

1. **No slot** (once the launcher has published its initial scan): the database is not enabled. Hard error, no build attempted. If the slot is missing specifically because the array is full, the error says so distinctly ("vamana worker slots exhausted"; hint: increase `svs.max_databases`) rather than misdiagnosing it as "not enabled," because the database *was* configured; the operator's corrective action is different.
2. **Slot present, worker process ID still zero:** the database is enabled and the worker is starting. Proceed with the existing bounded wait.
3. **Slot present, worker process ID set:** available, proceed normally.

The configuration question and the liveness question are answered by two separate, deliberately un-conflated pieces:

- The **configuration** check asks "is this database enabled?" It either returns or hard-errors; it never spins. It treats "no slot" as authoritative only after the launcher's initial-scan flag is set; before that, it returns without erroring, because a valid database is briefly indistinguishable from an unconfigured one in the pre-publish window.
- The **liveness** wait asks "is a worker live and serving now?" It tolerates the startup window in which the slot exists but the worker process ID is not yet set. It re-checks configuration on each iteration, so that the instant the initial-scan flag flips with no slot present, it fails fast with a crisp configuration error instead of spinning to the startup timeout.

Keeping these two separate is what prevents a regression that an earlier design hit: keying the configuration question on slot presence (a liveness artifact) made every operation in a correctly configured database hard-error during the worker's startup window.

### The disable-side race is accepted, not closed

The commit-time reservation closes the enable-side race. There is deliberately no mirror mechanism on the disable side. A `CREATE INDEX` racing a disable can observe a stale "available" slot for up to one reconcile interval. This is accepted because the two races are not symmetric:

- The enable-side race, left unclosed, produces a hard, incorrect error on a build that should have succeeded: a real functional bug with no workaround but retry.
- The disable-side race produces at worst a build that proceeds against a worker about to drain and stop. The existing bounded-wait-and-timeout machinery already handles "worker not actually available" correctly: the build either completes against a still-up worker or times out with the existing, already-correct error. There is no incorrect-success case and no silent-corruption case, only a bounded window where a build might wait slightly longer before getting the outcome it would have gotten anyway.

Given that asymmetry, adding a second synchronous mechanism to close a race whose worst case is "try again shortly" would double the surface area of a subtle mechanism for no correctness gain. It is documented as a bounded gap rather than built.

---

## 12. Observability

A per-database statistics view reports one row per reserved slot. It reports a row for every reserved slot regardless of whether that slot's worker is currently running, the same way PostgreSQL's activity and replication views show rows for connections and slots regardless of transient state, rather than filtering to a healthy subset. A slot whose worker process ID is zero (enabled but not yet started, or crashed and not yet respawned) is exactly the state an operator most needs to see.

Each row carries at least the database OID, the worker's state, and the index count for that database. The index count is the same shared-memory counter the removal safety check reads; an operator auditing idle workers can spot a zero index count directly rather than discovering a forgotten catalog row by accident.

Because the view is cross-database, a query that cares about the current database must filter by its database OID; a superuser otherwise sees rows for every enabled database in the cluster, including the launcher's home-database slots.

---

## 13. Configuration Parameters

| Parameter | Class | Role |
|---|---|---|
| `svs.launcher_database` | postmaster | The database the launcher connects to in order to read the configuration catalog. The only remaining parameter that names a specific database; a one-time install choice. |
| `svs.max_databases` | postmaster | Sizes the per-database shared-memory array. Cannot change without a restart. Default sized for a typical number of Vamana-enabled databases plus headroom. |
| `svs.worker_restart_time` | postmaster | Governs the launcher's *own* crash-restart interval (via its static registration). No longer read by any per-database worker. |
| `svs.worker_restart_backoff` | reloadable | The base interval the launcher uses for per-database worker crash-restart backoff. Read only by the launcher's own restart logic. Deliberately separate from `svs.worker_restart_time`, because the two govern different restart policies (a fixed interval for the launcher itself, versus escalating backoff for per-database workers) that merely share a plausible default. |
| `svs.worker_startup_timeout_ms` | reloadable | Cluster-wide bound on the wait for a worker that is enabled but not yet available. No per-database override. |
| `svs.worker_timeout_ms` | reloadable | Cluster-wide bound on an individual IPC request. No per-database override. |
| `svs.shutdown_drain_budget_ms` | reloadable | Time budget for a worker's shutdown drain, checked between indexes. A single in-progress checkpoint is not preemptible, so the real bound is this budget plus one checkpoint's worst case. |
| `svs.worker_stop_timeout_ms` | reloadable | How long the launcher waits for a restarting worker's handle to report stopped before giving up. Does not force-kill; the restart stays pending until the worker exits naturally. |

The pre-existing checkpoint and replication parameters (`svs.checkpoint_debounce_window`, `svs.checkpoint_min_ops`, `svs.max_slot_wal_size`) are unchanged by this design; drain-and-stop builds on the same checkpoint path they govern.

The following genuinely require a restart, and only these: the launcher itself (statically registered), `svs.launcher_database`, `svs.max_databases`, and `svs.worker_restart_time`. Everything else about enablement is a runtime catalog change.

The per-database worker crash-backoff ceiling is a named internal constant rather than a parameter, on the principle that the base interval is already the operator knob and promoting the constant to a parameter later is a trivial, non-breaking change if a need appears.

---

## 14. Standby and Replication Behavior

All of the worker's standby-specific behavior is preserved unchanged in the per-database model, because none of it was ever specific to the single-worker design:

- The warning about hot-standby feedback on connect.
- Every branch in the worker's main loop that is gated on the current replay role: write-IPC processing, slot draining, and promotion handling.
- The launcher itself is registered to start in the consistent-recovery state, for the same reason the old static worker was: it must be able to run, and therefore spawn per-database workers, on a hot standby, where the normal "recovery finished" transition never fires.

A per-database worker binds to its database by OID at startup. If a database is dropped in the window between the launcher resolving its OID and the worker connecting, the worker's connection attempt fails cleanly and fatally before it ever publishes a process ID. This is benign and self-healing: because the worker is registered never to auto-restart, the postmaster signals the launcher, the launcher's ledger entry clears, and the next tolerant scan simply omits the dropped database. No orphaned state remains, and no redundant pre-connect OID re-verification is attempted, because the connection is the real serialization point and re-checking earlier would be a time-of-check-to-time-of-use non-fix.
