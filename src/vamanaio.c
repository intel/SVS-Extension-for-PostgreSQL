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

#include <sys/stat.h>

/*
 * On-disk header prefixing the sidecar TID-map file.  Records the slot count
 * so the loader can reject a file written at a different capacity or format
 * instead of silently zero-filling a short read.  Bump the version on any
 * format change.
 */
#define VAMANA_TIDMAP_MAGIC		0x53565354	/* "SVST" */
#define VAMANA_TIDMAP_VERSION	1

typedef struct VamanaTidMapHeader
{
	uint32		magic;
	uint32		version;
	uint32		capacity;		/* ItemPointerData slots following the header */
	uint32		reserved;		/* zero; pads to 8-byte alignment */
} VamanaTidMapHeader;

StaticAssertDecl(sizeof(VamanaTidMapHeader) == 16,
				 "VamanaTidMapHeader size changed — update readers/writers");

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
 * Create the directory hierarchy needed to save an index.
 * Creates $PGDATA/vamana_indexes/, .../<dboid>/, and .../<dboid>/<relid>/.
 */
void
VamanaEnsureSaveDir(Oid dboid, Oid relid)
{
	char		parentdir[MAXPGPATH];
	char		dbdir[MAXPGPATH];
	char		indexdir[MAXPGPATH];

	snprintf(parentdir, sizeof(parentdir), "%s/vamana_indexes", DataDir);
	VamanaMakeDirectoryOrError(parentdir);

	snprintf(dbdir, sizeof(dbdir), "%s/%u", parentdir, dboid);
	VamanaMakeDirectoryOrError(dbdir);

	VamanaGetIndexSavePath(dboid, relid, indexdir, sizeof(indexdir));
	VamanaMakeDirectoryOrError(indexdir);
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
 * write() the whole buffer, looping over short writes.  Returns false with
 * errno set on failure; a short write that leaves errno clear means the
 * filesystem is full.
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
VamanaSaveTidMapAtomically(Oid dboid, Oid relid, ItemPointerData *tidMapping, int count)
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
				 errmsg("could not flush TID map for vamana index %u: %m", relid),
				 errdetail_log("Path: \"%s\".", tidmaptmp)));
	}

	if (rename(tidmaptmp, tidmappath) != 0)
	{
		int			save_errno = errno;

		unlink(tidmaptmp);		/* do not leave the temp file behind */
		errno = save_errno;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not save TID map for vamana index %u: %m", relid),
				 errdetail_log("Rename \"%s\" to \"%s\".", tidmaptmp, tidmappath)));
	}
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
 * absent, unreadable, malformed, truncated, or larger than the metapage claims.
 *
 * tidMapping must be pre-allocated with at least tidMappingCapacity elements.
 */
bool
VamanaLoadTidMap(Oid dboid, Oid relid, ItemPointerData *tidMapping, int tidMappingCapacity)
{
	char		indexdir[MAXPGPATH];
	char		tidmappath[MAXPGPATH];
	FILE	   *f;
	VamanaTidMapHeader header;

	VamanaGetIndexSavePath(dboid, relid, indexdir, sizeof(indexdir));
	snprintf(tidmappath, sizeof(tidmappath), "%s/tidmap.bin", indexdir);

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

/* Guarantees buf's content lock is released even if GenericXLogFinish throws. */
static void
VamanaFinishAndReleaseBuffer(GenericXLogState *state, Buffer buf)
{
	PG_TRY();
	{
		GenericXLogFinish(state);
	}
	PG_CATCH();
	{
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
 */
static void
VamanaMarkIndexSaved(Relation index, ForkNumber forkNum, const VamanaIndexCache *meta)
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
 */
void
VamanaSaveIndexToDisk(Relation index, SVSIndexHandle svsIndex, ForkNumber forkNum,
					  const VamanaIndexCache *meta)
{
	char		savepath[MAXPGPATH];
	Oid			relid = RelationGetRelid(index);

	/* Temporary indexes are session-private; never serialize them. */
	if (index->rd_rel->relpersistence == RELPERSISTENCE_TEMP)
		return;

	PG_TRY();
	{
		VamanaEnsureSaveDir(MyDatabaseId, relid);
		VamanaGetIndexSavePath(MyDatabaseId, relid, savepath, sizeof(savepath));

		ereport(DEBUG1,
				(errmsg("saving vamana index for relation %u", relid),
				 errdetail_log("Path: \"%s\".", savepath)));

		SVSSaveIndex(svsIndex, savepath);

		/*
		 * Build-time TID order must be preserved: a heap re-scan after VACUUM
		 * may visit tuples in different physical order and would map SVS IDs
		 * to wrong TIDs.
		 */
		if (meta->tidMapping != NULL && meta->tidMappingCapacity > 0)
			VamanaSaveTidMapAtomically(MyDatabaseId, relid, meta->tidMapping, meta->tidMappingCapacity);
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
	 * (VamanaObjectAccessHook cleans it up) or until the next save attempt,
	 * which will overwrite the stale files.
	 */
	VamanaMarkIndexSaved(index, forkNum, meta);

	VamanaCacheSetNeedsSave(relid, false);

	ereport(DEBUG1,
			(errmsg("vamana index for relation %u saved (%d vectors)", relid, meta->numVectors)));
}
