/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamanaio.c
 *
 * On-disk serialization for Vamana indexes: save-directory management,
 * TID-map I/O, and metapage flag updates tied to I/O state.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamanaworker.h"
#include "svs_wrapper.h"

#include "access/generic_xlog.h"
#include "common/file_perm.h"
#include "miscadmin.h"
#include "port.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "storage/fd.h"
#include "utils/injection_point.h"
#include "utils/rel.h"
#include "utils/timestamp.h"

#include <sys/stat.h>

/*
 * On-disk header prefixing the sidecar TID-map file.  Records the slot count
 * so the loader can reject a file written at a different capacity or format
 * instead of silently zero-filling a short read.  Bump the version on any
 * format change.
 *
 * generation carries the same save-generation stamp as the metapage's
 * saveGeneration and the save directory's generation marker (see
 * VamanaSaveGenHeader below); the loader rejects any disagreement among the
 * three as a torn save instead of serving it.
 */
#define VAMANA_TIDMAP_MAGIC		0x53565354	/* "SVST" */
#define VAMANA_TIDMAP_VERSION	2

typedef struct VamanaTidMapHeader
{
	uint32		magic;
	uint32		version;
	uint32		capacity;		/* ItemPointerData slots following the header */
	uint32		reserved;		/* zero; pads to 8-byte alignment */
	TimestampTz generation;	/* save-generation stamp; see comment above */
} VamanaTidMapHeader;

StaticAssertDecl(sizeof(VamanaTidMapHeader) == 24,
				 "VamanaTidMapHeader size changed — update readers/writers");

/*
 * On-disk header for the save directory's generation marker file
 * (generation.bin).  Written durably before SVSSaveIndex begins overwriting
 * graph/data/config in place, so its presence and value answer "has a new
 * generation's graph write started" independently of whether that write
 * ever finished.  See VamanaSaveIndexToDisk for how the three stamps
 * (this marker, the TID map header above, and the metapage) are used
 * together to detect a torn save.
 */
#define VAMANA_SAVEGEN_MAGIC	0x53565347	/* "SVSG" */
#define VAMANA_SAVEGEN_VERSION	1

typedef struct VamanaSaveGenHeader
{
	uint32		magic;
	uint32		version;
	TimestampTz generation;
} VamanaSaveGenHeader;

StaticAssertDecl(sizeof(VamanaSaveGenHeader) == 16,
				 "VamanaSaveGenHeader size changed, update readers/writers");

/*
 * Construct the save-directory path for a vamana index.
 * Convention: $PGDATA/vamana_indexes/<dboid>/<relid>/
 *
 * relid alone would not be unique: pg_class OIDs are per-database, and
 * CREATE DATABASE ... TEMPLATE can duplicate one across databases.
 */
void
VamanaGetIndexSavePath(Oid dboid, Oid relid, char *buf, size_t bufsz)
{
	snprintf(buf, bufsz, "%s/vamana_indexes/%u/%u", DataDir, dboid, relid);
}

static void
VamanaMakeDirectoryOrError(const char *path)
{
	if (MakePGDirectory(path) != 0 && errno != EEXIST)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create vamana index directory: %m"),
				 errdetail_log("Path: \"%s\".", path)));
}

/*
 * Subdirectories that svs_index_save creates under the save directory.
 * SVS's create_directory is a no-op on an existing directory, so creating
 * them here first gives them pg_dir_create_mode rather than a mode that
 * depends on the process umask.
 */
static const char *const VamanaSvsPayloadSubdirs[] = {"config", "graph", "data"};

/*
 * Create the directory hierarchy needed to save an index.
 * Creates $PGDATA/vamana_indexes/, .../<dboid>/, .../<dboid>/<relid>/, and
 * the config/, graph/, and data/ subdirectories that svs_index_save fills in.
 */
void
VamanaEnsureSaveDir(Oid dboid, Oid relid)
{
	char		parentdir[MAXPGPATH];
	char		dbdir[MAXPGPATH];
	char		indexdir[MAXPGPATH];
	char		subdir[MAXPGPATH];

	snprintf(parentdir, sizeof(parentdir), "%s/vamana_indexes", DataDir);
	VamanaMakeDirectoryOrError(parentdir);

	snprintf(dbdir, sizeof(dbdir), "%s/%u", parentdir, dboid);
	VamanaMakeDirectoryOrError(dbdir);

	VamanaGetIndexSavePath(dboid, relid, indexdir, sizeof(indexdir));
	VamanaMakeDirectoryOrError(indexdir);

	for (int i = 0; i < lengthof(VamanaSvsPayloadSubdirs); i++)
	{
		snprintf(subdir, sizeof(subdir), "%s/%s", indexdir, VamanaSvsPayloadSubdirs[i]);
		VamanaMakeDirectoryOrError(subdir);
	}
}

/*
 * Remove the on-disk save directory for a vamana index, if it exists.
 * Silently returns if the directory does not exist.
 */
void
VamanaDeleteSaveDir(Oid dboid, Oid relid)
{
	char		indexdir[MAXPGPATH];
	struct stat st;

	VamanaGetIndexSavePath(dboid, relid, indexdir, sizeof(indexdir));

	if (stat(indexdir, &st) != 0)
		return;

	if (rmtree(indexdir, true) == false)
		ereport(WARNING,
				(errmsg("could not remove vamana index directory for relation %u", relid),
				 errdetail_log("Path: \"%s\".", indexdir)));
}

/*
 * Construct the path of the temp file used to publish the TID map, given an
 * index save directory from VamanaGetIndexSavePath.
 *
 * The name is deterministic — no pid or random suffix — so that a temp file
 * orphaned by a crash can be recognized and removed later.  See the sweep at
 * the top of VamanaLoadTidMap.
 */
static void
VamanaGetTidMapTmpPath(const char *indexdir, char *buf, size_t bufsz)
{
	snprintf(buf, bufsz, "%s/tidmap.bin.tmp", indexdir);
}

/*
 * Construct the path of the save directory's generation marker file and its
 * temp-file counterpart, given an index save directory from
 * VamanaGetIndexSavePath.  Same deterministic-name rationale as
 * VamanaGetTidMapTmpPath: a temp file orphaned by a crash must be
 * recognizable and removable later.
 */
static void
VamanaGetSaveGenPath(const char *indexdir, char *buf, size_t bufsz)
{
	snprintf(buf, bufsz, "%s/generation.bin", indexdir);
}

static void
VamanaGetSaveGenTmpPath(const char *indexdir, char *buf, size_t bufsz)
{
	snprintf(buf, bufsz, "%s/generation.bin.tmp", indexdir);
}

/*
 * write() the whole buffer, looping over short writes.  Returns false with
 * errno set on failure.
 *
 * A write() of a non-zero count that returns 0 is not an error POSIX assigns a
 * cause to, and it can leave errno clear.  ENOSPC is substituted in that case
 * so the caller's %m reports a plausible cause rather than "Success" — a best
 * guess, not a determination that the filesystem is full.
 *
 * Deliberately contains no CHECK_FOR_INTERRUPTS: throwing from here would leak
 * the caller's transient fd and leave the temp file behind.  The loop is
 * bounded by the size of the TID map and makes forward progress on every
 * iteration.
 */
static bool
VamanaWriteFully(int fd, const void *data, size_t len)
{
	const char *p = (const char *) data;

	while (len > 0)
	{
		ssize_t		written;

		errno = 0;
		written = write(fd, p, len);

		if (written < 0)
		{
			if (errno == EINTR)
				continue;
			return false;
		}
		if (written == 0)
		{
			if (errno == 0)
				errno = ENOSPC;
			return false;
		}

		p += written;
		len -= (size_t) written;
	}

	return true;
}

/*
 * Durably stamp the save directory's generation marker with <generation>,
 * via the same write-to-tmp-then-rename pattern as VamanaSaveTidMapAtomically.
 *
 * Called at the start of VamanaSaveIndexToDisk, before SVSSaveIndex begins
 * overwriting graph/data/config in place.  This ordering is what closes the
 * torn-save window: a crash at any point from here through the end of the
 * save leaves this marker already at the new generation while the TID map
 * and/or metapage are still at the old one, so VamanaCheckSaveGeneration and
 * VamanaLoadTidMap's own check both see a mismatch and reject the save
 * instead of serving it.  A crash before this call leaves everything
 * (marker, graph, TID map, metapage) at the prior, fully consistent
 * generation.
 *
 * Ereports ERROR on I/O failure; caller's PG_TRY handles cleanup of the
 * entire save directory.
 */
static void
VamanaWriteSaveGeneration(Oid dboid, Oid relid, TimestampTz generation)
{
	char		indexdir[MAXPGPATH];
	char		genpath[MAXPGPATH];
	char		gentmp[MAXPGPATH];
	int			fd;
	VamanaSaveGenHeader header;

	VamanaGetIndexSavePath(dboid, relid, indexdir, sizeof(indexdir));
	VamanaGetSaveGenPath(indexdir, genpath, sizeof(genpath));
	VamanaGetSaveGenTmpPath(indexdir, gentmp, sizeof(gentmp));

	/* ENOENT is the expected case: usually there is nothing to clean up. */
	if (unlink(gentmp) != 0 && errno != ENOENT)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not remove stale save-generation temp file for vamana index %u: %m", relid),
				 errdetail_log("Path: \"%s\".", gentmp)));

	fd = OpenTransientFilePerm(gentmp,
							   O_WRONLY | O_CREAT | O_EXCL | PG_BINARY,
							   pg_file_create_mode);
	if (fd < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create save-generation file for vamana index %u: %m", relid),
				 errdetail_log("Path: \"%s\".", gentmp)));

	if (fchmod(fd, (mode_t) pg_file_create_mode) != 0)
	{
		int			save_errno = errno;

		CloseTransientFile(fd);
		unlink(gentmp);
		errno = save_errno;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not set permissions on save-generation file for vamana index %u: %m", relid),
				 errdetail_log("Path: \"%s\".", gentmp)));
	}

	header.magic = VAMANA_SAVEGEN_MAGIC;
	header.version = VAMANA_SAVEGEN_VERSION;
	header.generation = generation;

	if (!VamanaWriteFully(fd, &header, sizeof(header)))
	{
		int			save_errno = errno;

		CloseTransientFile(fd);
		unlink(gentmp);
		errno = save_errno;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not write save-generation file for vamana index %u: %m", relid),
				 errdetail_log("Path: \"%s\".", gentmp)));
	}

	if (CloseTransientFile(fd) != 0)
	{
		int			save_errno = errno;

		unlink(gentmp);
		errno = save_errno;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not close save-generation file for vamana index %u: %m", relid),
				 errdetail_log("Path: \"%s\".", gentmp)));
	}

	durable_rename(gentmp, genpath, ERROR);
}

/*
 * Write the TID mapping for a vamana index to a sidecar file inside its
 * save directory.  The file is a VamanaTidMapHeader followed by <count>
 * ItemPointerData slots.  Uses a write-to-tmp-then-rename pattern so a crash
 * mid-write does not leave a partial file that looks valid.
 *
 * The temp file's permissions are stated outright rather than left to any
 * creation default: it is created with pg_file_create_mode and fchmod()ed to
 * exactly that mode before any data is written, so the mode the rename
 * publishes onto tidmap.bin is the cluster's file mode and nothing else.
 * pg_file_create_mode is used in preference to a hardcoded 0600 so that a
 * cluster initialized with group access (initdb -g) keeps working.
 *
 * Any leftover temp file is removed before the new one is created.  That is
 * both cleanup and a correctness requirement: O_CREAT does not change the mode
 * of a file that already exists, so a stale temp left at a wider mode would
 * keep it and the rename would publish that mode onto tidmap.bin.  Removing it
 * first means O_EXCL below always creates the inode, so our mode applies.
 *
 * This relies on there being at most one saver per index at a time.  CREATE
 * INDEX holds AccessExclusiveLock on the index, and the background-worker save
 * paths for a given index all run inside that database's single worker; the
 * save directory is namespaced by database OID, so workers for different
 * databases never contend for the same temp file.
 *
 * Ereports ERROR on I/O failure; caller's PG_TRY handles cleanup of the
 * entire save directory.
 */
void
VamanaSaveTidMapAtomically(Oid dboid, Oid relid, ItemPointerData *tidMapping, int count,
							TimestampTz generation)
{
	char		indexdir[MAXPGPATH];
	char		tidmappath[MAXPGPATH];
	char		tidmaptmp[MAXPGPATH];
	int			fd;
	VamanaTidMapHeader header;

	VamanaGetIndexSavePath(dboid, relid, indexdir, sizeof(indexdir));
	snprintf(tidmappath, sizeof(tidmappath), "%s/tidmap.bin", indexdir);
	VamanaGetTidMapTmpPath(indexdir, tidmaptmp, sizeof(tidmaptmp));

	/* ENOENT is the expected case: usually there is nothing to clean up. */
	if (unlink(tidmaptmp) != 0 && errno != ENOENT)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not remove stale TID map temp file for vamana index %u: %m", relid),
				 errdetail_log("Path: \"%s\".", tidmaptmp)));

	fd = OpenTransientFilePerm(tidmaptmp,
							   O_WRONLY | O_CREAT | O_EXCL | PG_BINARY,
							   pg_file_create_mode);
	if (fd < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create TID map file for vamana index %u: %m", relid),
				 errdetail_log("Path: \"%s\".", tidmaptmp)));

	/*
	 * Make the mode exact rather than merely no wider than requested.  Safe to
	 * do on the fd before writing: the file is still empty.
	 */
	if (fchmod(fd, (mode_t) pg_file_create_mode) != 0)
	{
		int			save_errno = errno;

		/* Cleanup would overwrite the fchmod failure's errno before %m reads it. */
		CloseTransientFile(fd);
		unlink(tidmaptmp);
		errno = save_errno;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not set permissions on TID map file for vamana index %u: %m", relid),
				 errdetail_log("Path: \"%s\".", tidmaptmp)));
	}

	header.magic = VAMANA_TIDMAP_MAGIC;
	header.version = VAMANA_TIDMAP_VERSION;
	header.capacity = (uint32) count;
	header.reserved = 0;
	header.generation = generation;

	/*
	 * Unreachable on 64-bit systems: int count (max ~2.1e9) * 6 bytes fits
	 * comfortably in size_t.  Guards the multiplication as belt-and-braces and
	 * catches a negative count, which would cast to a huge size_t.
	 */
	if ((size_t) count > SIZE_MAX / sizeof(ItemPointerData))
	{
		CloseTransientFile(fd);
		unlink(tidmaptmp);
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("TID map too large to save for vamana index %u "
						"(%d entries exceeds size limit)",
						relid, count)));
	}

	if (!VamanaWriteFully(fd, &header, sizeof(header)) ||
		!VamanaWriteFully(fd, tidMapping,
						  (size_t) count * sizeof(ItemPointerData)))
	{
		int			save_errno = errno;

		/* Cleanup would overwrite the write failure's errno before %m reads it. */
		CloseTransientFile(fd);
		unlink(tidmaptmp);
		errno = save_errno;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not write TID map for vamana index %u: %m", relid),
				 errdetail_log("Path: \"%s\".", tidmaptmp)));
	}

	if (CloseTransientFile(fd) != 0)
	{
		int			save_errno = errno;

		unlink(tidmaptmp);
		errno = save_errno;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not close TID map for vamana index %u: %m", relid),
				 errdetail_log("Path: \"%s\".", tidmaptmp)));
	}

	/*
	 * durable_rename fsyncs the temporary file, then the renamed file and its
	 * containing directory, before returning.  A plain rename(2) leaves both
	 * the file contents and the new directory entry in the kernel's page cache,
	 * so a host-level crash could lose the entry and leave the index pointing
	 * at a TID map that was reported saved.  Raises ERROR on failure, which the
	 * caller's PG_TRY turns into a full save-directory cleanup.
	 */
	durable_rename(tidmaptmp, tidmappath, ERROR);
}

/*
 * Read back the sidecar TID-mapping file for a vamana index.
 *
 * The file was written at the last checkpoint and holds header.capacity slots.
 * tidMappingCapacity is the caller's current slot count from the metapage,
 * which is bumped on every insert and so may exceed the file's capacity when
 * inserts have occurred since that checkpoint.  Those extra slots are recent
 * inserts replayed from WAL, not persisted state; they are initialized to the
 * invalid TID here so the caller sees them as empty holes.
 *
 * Returns true and fills all of tidMapping[0..tidMappingCapacity-1] on success.
 * Returns false (triggering caller to rebuild from the heap) if the file is
 * absent, unreadable, malformed, truncated, larger than the metapage claims,
 * or stamped with a save generation that disagrees with
 * expectedSaveGeneration (the metapage's own saveGeneration) -- the latter
 * is a torn save: a self-consistent, well-formed TID map left over from a
 * generation older or newer than the graph/data/config on disk.
 *
 * tidMapping must be pre-allocated with at least tidMappingCapacity elements.
 */
bool
VamanaLoadTidMap(Oid dboid, Oid relid, ItemPointerData *tidMapping, int tidMappingCapacity,
				 TimestampTz expectedSaveGeneration)
{
	char		indexdir[MAXPGPATH];
	char		tidmappath[MAXPGPATH];
	char		tidmaptmp[MAXPGPATH];
	struct stat tmpst;
	FILE	   *f;
	VamanaTidMapHeader header;

	VamanaGetIndexSavePath(dboid, relid, indexdir, sizeof(indexdir));
	snprintf(tidmappath, sizeof(tidmappath), "%s/tidmap.bin", indexdir);

	/*
	 * Remove a temp file orphaned by a crash between the write and the rename
	 * in VamanaSaveTidMapAtomically.  That save path clears its own leftovers,
	 * but it never runs again for an index that is only ever read from here on,
	 * so without this the orphan would persist indefinitely.  This has to
	 * happen before the ENOENT check below, since a missing tidmap.bin next to
	 * an orphaned temp file is exactly what a crash mid-save looks like.
	 *
	 * Only sweep a temp file older than this postmaster's start time.  Saves
	 * and loads do overlap — a BGW checkpoint and a backend load both hold only
	 * AccessShareLock — and unlinking a live writer's temp file between its
	 * close and its rename would fail that save and cost it the whole save
	 * directory.  A live writer's temp file is always newer than PgStartTime.
	 *
	 * Limitation: PgStartTime is set once at postmaster start and is not reset
	 * after crash recovery, so an orphan left by a crashed backend or worker in
	 * the current postmaster lifetime is not swept here.  For a read-only index
	 * that never saves again, such an orphan persists until the next save or
	 * until the index is dropped.  The tradeoff is intentional: unlinking a
	 * file that might be a live writer's temp is worse than leaving an orphan.
	 *
	 * Best effort only: this is hygiene on a read path whose contract is to
	 * return false and let the caller rebuild, so a failure here must not turn
	 * into a failed load.
	 */
	VamanaGetTidMapTmpPath(indexdir, tidmaptmp, sizeof(tidmaptmp));
	if (lstat(tidmaptmp, &tmpst) == 0 &&
		S_ISREG(tmpst.st_mode) &&
		tmpst.st_mtime < timestamptz_to_time_t(PgStartTime))
	{
		if (unlink(tidmaptmp) == 0)
			ereport(DEBUG1,
					(errmsg("vamana index %u: removed orphaned TID map temp file", relid),
					 errdetail_log("Path: \"%s\".", tidmaptmp)));
		else
			ereport(DEBUG1,
					(errcode_for_file_access(),
					 errmsg("vamana index %u: could not remove orphaned TID map temp file: %m", relid),
					 errdetail_log("Path: \"%s\".", tidmaptmp)));
	}

	f = AllocateFile(tidmappath, PG_BINARY_R);
	if (f == NULL)
	{
		if (errno == ENOENT)
			return false;		/* normal "no saved file" signal */
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("could not open TID map for vamana index %u: %m", relid),
				 errdetail_log("Path: \"%s\".", tidmappath)));
		return false;
	}

	if (fread(&header, sizeof(header), 1, f) != 1 ||
		header.magic != VAMANA_TIDMAP_MAGIC ||
		header.version != VAMANA_TIDMAP_VERSION ||
		header.capacity > (uint32) tidMappingCapacity)
	{
		FreeFile(f);
		ereport(WARNING,
				(errmsg("vamana index %u: TID map is malformed or larger "
						"than expected (%d slots), will rebuild",
						relid, tidMappingCapacity),
				 errdetail_log("Path: \"%s\".", tidmappath)));
		return false;
	}

	/*
	 * A well-formed TID map left over from a different save generation than
	 * the metapage's: the mismatch itself is the only evidence, since the
	 * file is otherwise complete and internally consistent.  See
	 * VamanaWriteSaveGeneration for which crash windows this catches.
	 */
	if (header.generation != expectedSaveGeneration)
	{
		FreeFile(f);
		ereport(WARNING,
				(errmsg("vamana index %u: TID map generation does not match "
						"the index's current generation, torn save detected, will rebuild",
						relid),
				 errdetail_log("Path: \"%s\".", tidmappath)));
		return false;
	}

	if (fread(tidMapping, sizeof(ItemPointerData), header.capacity, f)
		!= header.capacity)
	{
		FreeFile(f);
		ereport(WARNING,
				(errmsg("vamana index %u: TID map is truncated "
						"(expected %u slots), will rebuild",
						relid, header.capacity),
				 errdetail_log("Path: \"%s\".", tidmappath)));
		return false;
	}

	FreeFile(f);

	/* Slots past the persisted set are WAL-replayed inserts: mark them empty. */
	for (int i = (int) header.capacity; i < tidMappingCapacity; i++)
		ItemPointerSetInvalid(&tidMapping[i]);

	return true;
}

/*
 * Confirm the save directory's generation marker agrees with
 * expectedSaveGeneration (the metapage's own saveGeneration), independent of
 * whether a TID map load is also being attempted (an index with
 * tidMappingCapacity == 0 never calls VamanaLoadTidMap, but a torn graph is
 * still possible, so this is the generation check all load paths need).
 *
 * Returns false (triggering caller to rebuild from the heap) if the marker
 * is absent, unreadable, malformed, or stamped with a different generation
 * than expected.  Returns true only when the marker and the metapage agree,
 * meaning the on-disk graph/data/config and the metapage come from the same
 * completed save.
 */
bool
VamanaCheckSaveGeneration(Oid dboid, Oid relid, TimestampTz expectedSaveGeneration)
{
	char		indexdir[MAXPGPATH];
	char		genpath[MAXPGPATH];
	char		gentmp[MAXPGPATH];
	int			tmpfd;
	FILE	   *f;
	VamanaSaveGenHeader header;

	VamanaGetIndexSavePath(dboid, relid, indexdir, sizeof(indexdir));
	VamanaGetSaveGenPath(indexdir, genpath, sizeof(genpath));

	/*
	 * Same orphan-temp-file hygiene as VamanaLoadTidMap; see its comment.
	 * Checked via an open file descriptor rather than lstat-by-path so the
	 * mtime/mode this decides on belongs to the exact file the unlink below
	 * removes, not to whatever a later rename or recreation leaves at that
	 * path in between: a plain stat-then-unlink-by-name would let a
	 * concurrent writer's own temp-file replace land in that window and be
	 * removed instead of the orphan actually checked.
	 */
	VamanaGetSaveGenTmpPath(indexdir, gentmp, sizeof(gentmp));
	tmpfd = OpenTransientFile(gentmp, O_RDONLY | PG_BINARY);
	if (tmpfd >= 0)
	{
		struct stat tmpst;
		bool		is_orphan = fstat(tmpfd, &tmpst) == 0 &&
			S_ISREG(tmpst.st_mode) &&
			tmpst.st_mtime < timestamptz_to_time_t(PgStartTime);

		CloseTransientFile(tmpfd);

		if (is_orphan)
		{
			if (unlink(gentmp) == 0)
				ereport(DEBUG1,
						(errmsg("vamana index %u: removed orphaned save-generation temp file", relid),
						 errdetail_log("Path: \"%s\".", gentmp)));
			else
				ereport(DEBUG1,
						(errcode_for_file_access(),
						 errmsg("vamana index %u: could not remove orphaned save-generation temp file: %m", relid),
						 errdetail_log("Path: \"%s\".", gentmp)));
		}
	}

	f = AllocateFile(genpath, PG_BINARY_R);
	if (f == NULL)
	{
		if (errno == ENOENT)
		{
			ereport(WARNING,
					(errmsg("vamana index %u: save-generation marker missing, torn save detected, will rebuild",
							relid),
					 errdetail_log("Path: \"%s\".", genpath)));
			return false;
		}
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("could not open save-generation marker for vamana index %u: %m", relid),
				 errdetail_log("Path: \"%s\".", genpath)));
		return false;
	}

	if (fread(&header, sizeof(header), 1, f) != 1 ||
		header.magic != VAMANA_SAVEGEN_MAGIC ||
		header.version != VAMANA_SAVEGEN_VERSION)
	{
		FreeFile(f);
		ereport(WARNING,
				(errmsg("vamana index %u: save-generation marker is malformed, will rebuild",
						relid),
				 errdetail_log("Path: \"%s\".", genpath)));
		return false;
	}

	FreeFile(f);

	if (header.generation != expectedSaveGeneration)
	{
		ereport(WARNING,
				(errmsg("vamana index %u: save-generation marker does not match "
						"the index's current generation, torn save detected, will rebuild",
						relid),
				 errdetail_log("Path: \"%s\".", genpath)));
		return false;
	}

	return true;
}

/* Guarantees buf's content lock is released even if GenericXLogFinish throws. */
static void
VamanaFinishAndReleaseBuffer(GenericXLogState *state, Buffer buf)
{
	PG_TRY();
	{
		/* Test hook: TAP forces a failure that lands in the handler below. */
		INJECTION_POINT("vamana-finish-release-buffer-error", NULL);
		GenericXLogFinish(state);
	}
	PG_CATCH();
	{
		/*
		 * errfinish() zeroed InterruptHoldoffCount, including the hold the
		 * content lock's acquisition took.  Re-take it so the lock release's
		 * RESUME_INTERRUPTS() has one to consume, as LWLockReleaseAll() does.
		 */
		HOLD_INTERRUPTS();
		UnlockReleaseBuffer(buf);
		PG_RE_THROW();
	}
	PG_END_TRY();

	UnlockReleaseBuffer(buf);
}

/*
 * Update only the hasSavedIndex flag on the metapage.
 */
void
VamanaSetHasSavedIndex(Relation index, bool hasSavedIndex, ForkNumber forkNum)
{
	Buffer		buf;
	Page		page;
	GenericXLogState *state;
	VamanaMetaPage metap;

	buf = ReadBufferExtended(index, forkNum, VAMANA_METAPAGE_BLKNO,
							 RBM_NORMAL, NULL);
	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
	state = GenericXLogStart(index);
	page = GenericXLogRegisterBuffer(state, buf, 0);
	metap = VamanaPageGetMeta(page);
	metap->hasSavedIndex = hasSavedIndex;
	VamanaFinishAndReleaseBuffer(state, buf);
}

/*
 * Atomically write hasSavedIndex and all metapage state from <meta>.
 *
 * Kept out of line so a debugger can stop on entry by name.
 */
static pg_noinline void
VamanaMarkIndexSaved(Relation index, ForkNumber forkNum, const VamanaIndexCache *meta,
					  TimestampTz generation)
{
	Buffer		buf;
	Page		page;
	GenericXLogState *state;
	VamanaMetaPage metap;

	buf = ReadBufferExtended(index, forkNum, VAMANA_METAPAGE_BLKNO,
							 RBM_NORMAL, NULL);
	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
	state = GenericXLogStart(index);
	page = GenericXLogRegisterBuffer(state, buf, 0);
	metap = VamanaPageGetMeta(page);

	metap->hasSavedIndex = true;
	metap->indexDataBlkno = VAMANA_HEAD_BLKNO;
	metap->indexDataSize = 0;
	metap->numVectors = (uint32) meta->numVectors;
	metap->nextExternalId = meta->nextExternalId;
	metap->numDeleted = (uint32) meta->numDeleted;
	metap->tidMappingCapacity = (uint32) meta->tidMappingCapacity;
	metap->saveGeneration = generation;

	/* Test hook: TAP forces a failure while buf's exclusive content lock is held. */
	INJECTION_POINT("vamana-mark-index-saved-error", NULL);

	VamanaFinishAndReleaseBuffer(state, buf);
}

/*
 * Save the SVS index for <index> to $PGDATA/vamana_indexes/<oid>/ and update
 * the metapage.  All index state is taken from <meta>.
 *
 * On failure: cleans up the partial save directory and re-raises the error.
 * The caller is responsible for error handling policy.
 *
 * compactedOut, if not NULL, is set to true as soon as SVSSaveIndex succeeds.
 * SVSSaveIndex compacts the live in-memory graph as a side effect before
 * writing anything, so a caller that tracks compaction-driven accounting
 * (e.g. a checkpoint's residency reconciliation) needs to know whether that
 * happened even when a later step in this function (the TID-map write, or
 * VamanaMarkIndexSaved after this function's own PG_TRY) still fails.
 */
void
VamanaSaveIndexToDisk(Relation index, SVSIndexHandle svsIndex, ForkNumber forkNum,
					  const VamanaIndexCache *meta, bool volatile *compactedOut)
{
	char		savepath[MAXPGPATH];
	Oid			relid = RelationGetRelid(index);

	/*
	 * One stamp for this save, written to the generation marker before
	 * anything else changes, then carried through to the TID map and the
	 * metapage.  A fresh, strictly-increasing-in-practice value is all that
	 * is needed: the load path only ever checks equality across the three
	 * places it is stamped, never ordering, and this function's own callers
	 * already guarantee at most one saver per index at a time (see
	 * VamanaSaveTidMapAtomically's comment).
	 */
	TimestampTz generation = GetCurrentTimestamp();

	/* Temporary indexes are session-private; never serialize them. */
	if (index->rd_rel->relpersistence == RELPERSISTENCE_TEMP)
		return;

	PG_TRY();
	{
		VamanaEnsureSaveDir(MyDatabaseId, relid);
		VamanaGetIndexSavePath(MyDatabaseId, relid, savepath, sizeof(savepath));

		/*
		 * Stamp the new generation before SVSSaveIndex starts overwriting
		 * graph/data/config in place.  See VamanaWriteSaveGeneration for why
		 * this ordering, not writing the marker after SVSSaveIndex returns,
		 * is what closes the torn-save window: any crash from here through
		 * VamanaMarkIndexSaved below leaves this marker at the new
		 * generation while something else (the graph itself, mid-overwrite;
		 * or the TID map or metapage, not yet updated) is still at the old
		 * one, which the load path's generation check rejects.
		 */
		VamanaWriteSaveGeneration(MyDatabaseId, relid, generation);

		ereport(DEBUG1,
				(errmsg("saving vamana index for relation %u", relid),
				 errdetail_log("Path: \"%s\".", savepath)));

		SVSSaveIndex(svsIndex, savepath);

		if (compactedOut != NULL)
			*compactedOut = true;

		/*
		 * Build-time TID order must be preserved: a heap re-scan after VACUUM
		 * may visit tuples in different physical order and would map SVS IDs
		 * to wrong TIDs.
		 */
		if (meta->tidMapping != NULL && meta->tidMappingCapacity > 0)
			VamanaSaveTidMapAtomically(MyDatabaseId, relid, meta->tidMapping, meta->tidMappingCapacity,
										generation);
	}
	PG_CATCH();
	{
		VamanaDeleteSaveDir(MyDatabaseId, relid);
		PG_RE_THROW();
	}
	PG_END_TRY();

	/*
	 * Record that a valid on-disk copy now exists (single atomic WAL record).
	 *
	 * Note on transactional semantics: the disk files written by SVSSaveIndex
	 * above are outside PostgreSQL's transaction system: they are not rolled
	 * back if the surrounding transaction aborts. VamanaMarkIndexSaved uses
	 * GenericXLogFinish which is also not transactional in the usual sense;
	 * however it only reaches here after SVSSaveIndex succeeded, so the files
	 * and the flag are always in sync. If the transaction aborts after this
	 * point, the flag remains set and the files are valid: no harm done. If
	 * the server crashes after SVSSaveIndex but before VamanaMarkIndexSaved,
	 * the partial directory persists until the index is dropped
	 * (VamanaObjectAccessHook cleans it up) or until the next save attempt
	 * overwrites it; in the meantime, the generation marker written above
	 * already disagrees with the metapage's still-old saveGeneration, so a
	 * load in between is rejected and rebuilt rather than served torn.
	 */
	VamanaMarkIndexSaved(index, forkNum, meta, generation);

	VamanaCacheSetNeedsSave(relid, false);

	ereport(DEBUG1,
			(errmsg("vamana index for relation %u saved (%d vectors)", relid, meta->numVectors)));
}
