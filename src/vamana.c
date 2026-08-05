/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * Vamana index access method for pgvector
 *
 * This implements a PostgreSQL index access method using Intel's SVS library
 * with the Vamana graph-based algorithm for approximate nearest neighbor search.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamanalauncher.h"
#include "vamanaworker.h"

#include "access/amapi.h"
#include "access/reloptions.h"
#include "catalog/index.h"
#include "commands/vacuum.h"
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "storage/bufmgr.h"
#include "storage/indexfsm.h"
#include "storage/ipc.h"
#include "storage/shmem.h"
#include "utils/fmgroids.h"
#include "utils/guc.h"
#include "utils/rel.h"
#include "utils/selfuncs.h"

#if PG_VERSION_NUM >= 120000
#include "commands/progress.h"
#endif

#if PG_VERSION_NUM >= 130000
#include "utils/backend_status.h"
#endif

int			vamana_search_window_size = VAMANA_DEFAULT_SEARCH_WINDOW;
int			vamana_search_num_threads = 0;
int			vamana_compact_threshold_pct = 10;

int			max_vamana_databases = 8;
int			vamana_worker_timeout_ms = 5000;
int			vamana_worker_startup_timeout_ms = 60000;
int			vamana_worker_restart_time = 5;
int			vamana_worker_restart_backoff = 1000;
int			vamana_max_batch_size = 0;
char	   *vamana_launcher_database = NULL;

int			vamana_checkpoint_debounce_window = 300;
int			vamana_checkpoint_max_interval = 3600;
int			vamana_checkpoint_min_ops = 10000;
int			vamana_max_slot_wal_size_mb = 10240;	/* 10 GB */
int			vamana_checkpoint_operations = -1;		/* -1 = off (simple count-based trigger) */
int			vamana_checkpoint_interval = -1;		/* -1 = off (simple time-based trigger) */

relopt_kind vamana_relopt_kind;

void
VamanaInit(void)
{
	vamana_relopt_kind = add_reloption_kind();
	add_int_reloption(vamana_relopt_kind, "graph_degree", "Graph degree (R parameter)",
					  VAMANA_DEFAULT_GRAPH_DEGREE, VAMANA_MIN_GRAPH_DEGREE, VAMANA_MAX_GRAPH_DEGREE,
					  AccessExclusiveLock);
	add_int_reloption(vamana_relopt_kind, "alpha", "Alpha parameter for pruning (-1 = SVS default, else value * 0.01)",
					  VAMANA_DEFAULT_ALPHA, VAMANA_MIN_ALPHA, VAMANA_MAX_ALPHA,
					  AccessExclusiveLock);
	add_int_reloption(vamana_relopt_kind, "build_window_size", "Build window size (-1 = 2 * graph_degree)",
					  VAMANA_DEFAULT_BUILD_WINDOW, VAMANA_MIN_BUILD_WINDOW, VAMANA_MAX_BUILD_WINDOW,
					  AccessExclusiveLock);
	add_int_reloption(vamana_relopt_kind, "search_window_size", "Search window size for build and query (-1 = 100)",
					  VAMANA_DEFAULT_SEARCH_WINDOW, VAMANA_MIN_SEARCH_WINDOW, VAMANA_MAX_SEARCH_WINDOW,
					  AccessExclusiveLock);
	add_bool_reloption(vamana_relopt_kind, "use_search_history", "Maintain visited set during search (default true)",
					   VAMANA_DEFAULT_USE_SEARCH_HISTORY, AccessExclusiveLock);
	add_int_reloption(vamana_relopt_kind, "compression_type",
					  "Compression type (0=none, 1=leanvec, 2=lvq)",
					  VAMANA_DEFAULT_COMPRESSION_TYPE, 0, 2,
					  AccessExclusiveLock);
	add_int_reloption(vamana_relopt_kind, "compression_primary", "LeanVec primary quantization (4=UINT4, -4=INT4, 8=UINT8, -8=INT8)",
					  VAMANA_DEFAULT_LEANVEC_PRIMARY, -8, 8, AccessExclusiveLock);
	add_int_reloption(vamana_relopt_kind, "compression_secondary", "LeanVec secondary quantization (4=UINT4, -4=INT4, 8=UINT8, -8=INT8)",
					  VAMANA_DEFAULT_LEANVEC_SECONDARY, -8, 8, AccessExclusiveLock);
	add_int_reloption(vamana_relopt_kind, "leanvec_dims", "LeanVec dimensions (-1 = dimensions/2)",
					  VAMANA_DEFAULT_LEANVEC_DIMS, VAMANA_MIN_LEANVEC_DIMS, VAMANA_MAX_LEANVEC_DIMS, AccessExclusiveLock);

	DefineCustomIntVariable("svs.search_window_size",
							"Sets the search window size for vamana index scans",
							"Valid range is 10-10000. Higher values improve recall but increase latency.",
							&vamana_search_window_size,
							VAMANA_DEFAULT_SEARCH_WINDOW,
							VAMANA_MIN_SEARCH_WINDOW,
							VAMANA_MAX_SEARCH_WINDOW,
							PGC_USERSET,
							0,
							NULL,
							NULL,
							NULL);

	DefineCustomIntVariable("svs.search_num_threads",
							"Sets the number of threads SVS uses for index search operations",
							"0 = auto (nproc-1). Explicit values override auto. "
							"Lower values reduce oversubscription under concurrent query load; "
							"higher values increase per-query search parallelism.",
							&vamana_search_num_threads,
							0,	/* default: auto (resolves to nproc-1) */
							0,	/* min: 0 = auto */
							1024,	/* max */
							PGC_SUSET,
							0,
							NULL,
							NULL,
							NULL);

	/*
	 * Use PGC_POSTMASTER when loaded at server start so PostgreSQL enforces
	 * restart-only semantics.  Fall back to PGC_SIGHUP when loaded at runtime
	 * (CREATE EXTENSION / LOAD) — the worker isn't running anyway.
	 */
	{
		GucContext	worker_startup_ctx = process_shared_preload_libraries_in_progress
			? PGC_POSTMASTER : PGC_SIGHUP;

		DefineCustomIntVariable("svs.max_databases",
								"Maximum number of databases that can run a vamana background worker",
								"Sizes the per-database control-block array in shared memory. "
								"Requires a server restart to take effect.",
								&max_vamana_databases,
								8, 1, 128,
								worker_startup_ctx,
								0,
								NULL, NULL, NULL);

		DefineCustomIntVariable("svs.worker_restart_time",
								"Seconds to wait before restarting the background worker after a crash",
								"Set to -1 to disable automatic restart (BGW_NEVER_RESTART). "
								"Requires a server restart to take effect.",
								&vamana_worker_restart_time,
								5, -1, 300,
								worker_startup_ctx,
								0,
								NULL, NULL, NULL);

		DefineCustomStringVariable("svs.launcher_database",
								   "Database the launcher connects to in order to read vamana_databases",
								   "The launcher reads its list of enabled databases from the "
								   "vamana_databases catalog table in this database.  Set this once at "
								   "install time; changing it requires a server restart to take effect.",
								   &vamana_launcher_database,
								   "postgres",
								   worker_startup_ctx,
								   0,
								   NULL, NULL, NULL);
	}

	DefineCustomIntVariable("svs.worker_restart_backoff",
							"Base milliseconds the launcher waits before respawning a crashed per-database worker",
							"Applied with escalating backoff on repeated crashes of the same "
							"database's worker.  Read only by the launcher's crash-restart logic; "
							"distinct from svs.worker_restart_time, which governs the launcher's own "
							"restart by the postmaster.",
							&vamana_worker_restart_backoff,
							1000, 100, 300000,
							PGC_SIGHUP,
							GUC_UNIT_MS,
							NULL, NULL, NULL);

	DefineCustomIntVariable("svs.worker_timeout_ms",
							"Milliseconds to wait for background worker IPC response",
							NULL,
							&vamana_worker_timeout_ms,
							5000, 100, 60000,
							PGC_SIGHUP,
							0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("svs.worker_startup_timeout_ms",
							"Milliseconds to wait for the background worker to finish startup before erroring",
							"Increase this if the server has many large indexes or slow disk.",
							&vamana_worker_startup_timeout_ms,
							60000, 1000, 300000,
							PGC_SIGHUP,
							0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("svs.max_batch_size",
							"Maximum queries per SVS batch call (0 = MaxBackends)",
							NULL,
							&vamana_max_batch_size,
							0, 0, 1000,
							PGC_SIGHUP,
							0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("svs.compact_threshold_pct",
							"Percent-deleted threshold that triggers SVS compact during VACUUM cleanup",
							"0 = compact on every VACUUM with pending deletes. "
							"100 = disable compact (consolidate still runs). "
							"Higher values reduce compact frequency and memory reclamation; "
							"lower values keep the index tighter at the cost of more frequent compacts.",
							&vamana_compact_threshold_pct,
							10, 0, 100,
							PGC_USERSET,
							0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("svs.checkpoint_debounce_window",
							"Seconds of write inactivity to wait before triggering a checkpoint after a burst",
							"Works with svs.checkpoint_min_ops: both must be satisfied before a checkpoint "
							"fires (AND-logic). Prevents expensive checkpoints during brief idle gaps in "
							"otherwise active workloads.",
							&vamana_checkpoint_debounce_window,
							300, 0, 86400,
							PGC_SIGHUP,
							GUC_UNIT_S,
							NULL, NULL, NULL);

	DefineCustomIntVariable("svs.checkpoint_max_interval",
							"Maximum seconds between checkpoints when svs.checkpoint_min_ops is met",
							"Safety net for sustained-write workloads that never go quiet: ensures the "
							"replication slot advances and WAL does not accumulate unboundedly even if "
							"the debounce window never fires.",
							&vamana_checkpoint_max_interval,
							3600, 1, 86400,
							PGC_SIGHUP,
							GUC_UNIT_S,
							NULL, NULL, NULL);

	DefineCustomIntVariable("svs.checkpoint_min_ops",
							"Minimum number of index operations required before a checkpoint is eligible",
							"Acts as a filter in the AND-logic debounce: prevents costly full-graph saves "
							"for trivial write volumes where replaying from the slot on restart would be "
							"cheaper than the checkpoint itself.",
							&vamana_checkpoint_min_ops,
							10000, 0, INT_MAX,
							PGC_SIGHUP,
							0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("svs.max_slot_wal_size",
							"Maximum replication slot WAL lag in megabytes before dropping and rebuilding from heap",
							"If the slot falls this far behind (BGW down, infrequent checkpoints, or long "
							"transactions), the slot is dropped and the index is rebuilt from the heap on "
							"next BGW startup to bound disk usage.",
							&vamana_max_slot_wal_size_mb,
							10240, 64, MAX_KILOBYTES,
							PGC_SIGHUP,
							GUC_UNIT_MB,
							NULL, NULL, NULL);

	/*
	 * Simple count/time-based checkpoint triggers, independent of debounce logic.
	 * -1 (off) means the AND-logic debounce controls checkpoint timing.
	 * Setting either to a positive value activates simple OR-logic behavior instead.
	 */
	DefineCustomIntVariable("svs.checkpoint_operations",
							"Operation count trigger for checkpoint (-1 = off; independent of debounce logic)",
							NULL,
							&vamana_checkpoint_operations,
							-1, -1, INT_MAX,
							PGC_SIGHUP,
							0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("svs.checkpoint_interval",
							"Time-based trigger for checkpoint in seconds (-1 = off; independent of debounce logic)",
							NULL,
							&vamana_checkpoint_interval,
							-1, -1, 86400,
							PGC_SIGHUP,
							GUC_UNIT_S,
							NULL, NULL, NULL);

	MarkGUCPrefixReserved("svs");

	/*
	 * Register shared memory and background worker.  Must be done during
	 * shared_preload_libraries loading; skip when loaded via LOAD at runtime.
	 */
	if (process_shared_preload_libraries_in_progress)
	{
		VamanaWorkerInstallHooks();
		VamanaLauncherRegister();
	}

	/*
	 * Install an object-access hook to clean up on-disk save directories when
	 * a vamana index (or its parent table) is dropped.  PostgreSQL has no
	 * amdroptable callback in IndexAmRoutine; this hook fires on OAT_DROP and
	 * is the correct way to intercept DROP INDEX / DROP TABLE.
	 */
	VamanaInstallObjectAccessHook();
}

int
VamanaGetGraphDegree(Relation index)
{
	VamanaOptions *opts = (VamanaOptions *) index->rd_options;

	if (opts)
		return opts->graph_degree;

	return VAMANA_DEFAULT_GRAPH_DEGREE;
}

int
VamanaGetAlpha(Relation index)
{
	VamanaOptions *opts = (VamanaOptions *) index->rd_options;

	if (opts)
		return opts->alpha;

	return VAMANA_DEFAULT_ALPHA;
}

FUNCTION_PREFIX PG_FUNCTION_INFO_V1(vamanahandler);
Datum
vamanahandler(PG_FUNCTION_ARGS)
{
	IndexAmRoutine *amroutine = makeNode(IndexAmRoutine);

	amroutine->amstrategies = 0;
	amroutine->amsupport = 3;
	amroutine->amcanorder = false;
	amroutine->amcanorderbyop = true;
	amroutine->amcanbackward = false;	/* backward scans not supported */
	amroutine->amcanunique = false;
	amroutine->amcanmulticol = false;
	amroutine->amoptionalkey = true;
	amroutine->amsearcharray = false;
	amroutine->amsearchnulls = false;
	amroutine->amstorage = false;
	amroutine->amclusterable = false;
	amroutine->ampredlocks = false;
	amroutine->amcanparallel = false;
	amroutine->amcaninclude = false;
	amroutine->amusemaintenanceworkmem = true;
	amroutine->amparallelvacuumoptions = VACUUM_OPTION_NO_PARALLEL;
	amroutine->amkeytype = InvalidOid;

	amroutine->ambuild = vamanabuild;
	amroutine->ambuildempty = vamanabuildempty;
	amroutine->aminsert = vamanainsert;
	amroutine->ambulkdelete = vamanabulkdelete;
	amroutine->amvacuumcleanup = vamanavacuumcleanup;
	amroutine->amcanreturn = NULL;
	amroutine->amcostestimate = vamanacostestimate;
	amroutine->amoptions = vamanaoptions;
	amroutine->amproperty = NULL;
	amroutine->ambuildphasename = vamanabuildphasename;
	amroutine->amvalidate = vamanavalidate;
	amroutine->amadjustmembers = NULL;
	amroutine->ambeginscan = vamanabeginscan;
	amroutine->amrescan = vamanarescan;
	amroutine->amgettuple = vamanagettuple;
	amroutine->amgetbitmap = NULL;
	amroutine->amendscan = vamanaendscan;
	amroutine->ammarkpos = NULL;
	amroutine->amrestrpos = NULL;
	amroutine->amestimateparallelscan = NULL;
	amroutine->aminitparallelscan = NULL;
	amroutine->amparallelrescan = NULL;

	PG_RETURN_POINTER(amroutine);
}
