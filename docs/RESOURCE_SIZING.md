# Resource Sizing for Operators

This guide covers the background-worker and CPU resource settings a DBA must size before
enrolling databases with the `svs` extension. It assumes the extension is already installed;
see [`docs/USER_GUIDE.md`](USER_GUIDE.md) for installation and index creation.

## Table of Contents

1. [Required Settings](#1-required-settings)
2. [Sizing `max_parallel_workers`](#2-sizing-max_parallel_workers)
3. [The Per-Database Levers](#3-the-per-database-levers)
4. [Reading `pg_stat_vamana_worker`](#4-reading-pg_stat_vamana_worker)
5. [Restart, Reload, or Neither](#5-restart-reload-or-neither)

## 1. Required Settings

Add the extension to `shared_preload_libraries` and restart the server:

```
shared_preload_libraries = 'svs'
```

This is sufficient on its own. `svs.so` does not call into `vector.so` at runtime; the two
extensions' preload order does not matter. `svs.control` declares `requires = 'vector'`, but that
is a SQL-level dependency on the `vector` type, satisfied when you run `CREATE EXTENSION vector`
(or let `CREATE EXTENSION svs` pull it in automatically), and has no bearing on preload order.

### `max_worker_processes`

Every background worker the extension uses, including the parked worker processes that stand
in for search threads, draws a slot from `max_worker_processes`. Size it as:

```
max_worker_processes >= 1                          (the launcher)
                       + 1 per enrolled database    (one worker each)
                       + logical replication workers, if used
                       + max_parallel_workers
```

Autovacuum workers do not count here: they draw from `autovacuum_worker_slots`, a separate
reserved-slot pool, not from `max_worker_processes`.

Worked example: 2 enrolled databases, no logical replication, `max_parallel_workers = 8`:

```
1 + 2 + 0 + 8 = 11
```

The PostgreSQL default of `max_worker_processes = 8` is not enough. This setting takes effect
only on restart.

### `svs.max_databases`

Sizes the per-database control-block array the extension keeps in shared memory; also restart
only. See [USER_GUIDE.md §6.1 "Capacity"](USER_GUIDE.md#capacity) for the default, range, and the
error you get if you enroll past the limit.

## 2. Sizing `max_parallel_workers`

This is the setting operators most often get wrong, because the extension's use of it does not
match the usual mental model of "workers run while a query runs."

**A database's granted search threads are held continuously for as long as its worker is
enrolled and live, not only while a search query is executing.** Once the launcher grants a
database N search threads, those N slots are parked and unavailable to anything else, whether or
not that database is currently being queried.

Size the pool for **how many databases you enroll, not how many queries run concurrently**:

```
max_parallel_workers >= sum of every enrolled database's effective search-thread grant
                       + headroom for concurrent CREATE INDEX
                       + headroom for core parallel query
```

The "headroom for concurrent `CREATE INDEX`" term is not a vague safety margin: an index build's
requested threads draw from the same `max_parallel_workers`-bounded pool as every enrolled
database's search demand. But the two are not symmetric competitors. Each database's configured
floor (`search_threads_reserved`) is protected outright before any build is considered, and above
that floor a database's elastic demand is weighted by its floor while a build's claim always
carries zero weight. A build is structurally the lowest-priority claimant in the pool: it can
only draw against elastic demand headroom, never against a database's floor. In practice this
means a build in progress can shrink under pressure from search demand, but not the reverse: a
build never reduces a database's protected floor.

An unconfigured enrolled database (no `search_num_threads` override in `vamana_databases`)
resolves to a **1-thread grant**. Concretely: `svs.max_databases` defaults to 8,
`max_parallel_workers` defaults to 8, and **eight enrolled databases at stock settings hold the
entire default parallel pool permanently, with zero SVS queries running**, leaving nothing for
core parallel query or a parallel `CREATE INDEX`.

This is expected behavior, not a leak. If you see it, raise `max_parallel_workers` (and
`max_worker_processes` with it, per the formula above) to the sum of what your enrolled databases
actually need plus your usual core-parallel-query headroom.

Unlike `max_worker_processes`, `max_parallel_workers` is a normal runtime GUC (`PGC_USERSET`):
any session can change it for itself with `SET`, no superuser required, and a cluster-wide change
via `postgresql.conf` takes effect on reload (`pg_reload_conf()` or `SIGHUP`) with no restart.

## 3. The Per-Database Levers

Per-database overrides live in the `vamana_databases` catalog table. `SELECT` on this table is
not granted to `PUBLIC`; query it as the table owner or a superuser. All three levers below take
effect live, with no restart: promptly on a primary, and within 180 seconds on a standby.

- **`search_num_threads`**: this database's search-thread request. `NULL` (the default) means
  "use the cluster default," which today resolves to a 1-thread grant. A positive value requests
  that many threads instead, still bounded by the shared pool and by
  `svs.max_search_threads_per_db` if you have set that GUC.
- **`search_threads_reserved`**: a floor for this database's grant. `NULL` (the default) means
  no floor: the database's request is pure best-effort against the shared pool and can be
  reduced when the pool is oversubscribed. A positive value is honored before anything else is
  distributed, but the guarantee is not unconditional: it is capped at this database's own
  effective desired thread count, that is, `search_num_threads` after it is clamped to
  `svs.max_search_threads_per_db` (if you have set that GUC), not the raw configured
  `search_num_threads` value. And if every enrolled database's configured floors together
  exceed `max_parallel_workers`, the floors themselves are cut down to fit, lowest database OID
  first. A database's own floor can therefore be silently reduced by *other* databases'
  configuration, not just by its own usage or request. Avoid this by keeping the sum of all
  configured floors within `max_parallel_workers`.
- **`maintenance_num_threads`**: the thread count requested for this database's index builds
  (`CREATE INDEX`, and the equivalent maintenance paths). `NULL` (the default) means "follow the
  cluster build-thread default." `0` means serial.

## 4. Reading `pg_stat_vamana_worker`

`pg_stat_vamana_worker` exposes, per enrolled database, what was asked for and what was actually
handed out. The four columns that matter for CPU sizing:

| Column | Meaning |
|---|---|
| `search_threads_desired` | What the database asked for, after resolving `search_num_threads` and clamping to any per-database ceiling. |
| `search_threads_granted` | What the launcher actually allotted from the shared `max_parallel_workers` pool. |
| `search_threads_reserved` | The floor actually honored for this database, `0` if none is configured. |
| `search_slots_registered` | What the worker actually holds after resizing to the grant. |

All four read `0` when a database's worker is not live.

Two distinct problems produce a shortfall, and they call for different fixes:

- **`search_threads_granted` below `search_threads_desired`:** the shared pool is
  oversubscribed. Raise `max_parallel_workers` (see §2).
- **`search_slots_registered` below `search_threads_granted`:** the worker was granted threads
  it could not register, which points at the `max_worker_processes` slot array being exhausted.
  Raise `max_worker_processes` (see §1); note this is restart-only, unlike
  `max_parallel_workers`.

Two server log lines are usually the first signal an operator sees, before ever querying the
view:

- `vamana launcher could not register worker for database "<name>"` with a hint to increase
  `max_worker_processes`: a per-database worker itself could not be registered (a
  `max_worker_processes` shortfall, distinct from a search-slot shortfall below).
- `svs cpu slots: holding N of M requested search slots for database "<name>"`: the worker is
  holding fewer search slots than it was granted, and clears to `svs cpu slots: shortfall
  cleared, holding N of M requested search slots for database "<name>"` once resolved.

The view has more columns than the four above, including several from the memory-management
domain (residency and search-scratch memory); run `\d+ pg_stat_vamana_worker` in `psql` for the
full, current list.

## 5. Restart, Reload, or Neither

| Setting | Effect timing |
|---|---|
| `max_worker_processes` | Restart only |
| `svs.max_databases` | Restart only |
| `max_parallel_workers` | `SET` (this session) immediately; `postgresql.conf` on reload (`SIGHUP`) |
| `vamana_databases.search_num_threads` | Live, no restart |
| `vamana_databases.search_threads_reserved` | Live, no restart |
| `vamana_databases.maintenance_num_threads` | Live, no restart |

**How quickly a change takes effect.** On a primary, a change to the `vamana_databases` table
takes effect promptly. On a standby, the change arrives through replication and is picked up
within 180 seconds. This interval is not configurable.
