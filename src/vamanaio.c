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
#include "miscadmin.h"
#include "port.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "storage/fd.h"
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
 * Convention: $PGDATA/vamana_indexes/<relid>/
 */
void
VamanaGetIndexSavePath(Oid relid, char *buf, size_t bufsz)
{
	snprintf(buf, bufsz, "%s/vamana_indexes/%u", DataDir, relid);
}

/*
 * Create the directory hierarchy needed to save an index.
 * Creates $PGDATA/vamana_indexes/ and $PGDATA/vamana_indexes/<relid>/.
 */
void
VamanaEnsureSaveDir(Oid relid)
{
	char		parentdir[MAXPGPATH];
	char		indexdir[MAXPGPATH];

	snprintf(parentdir, sizeof(parentdir), "%s/vamana_indexes", DataDir);
	if (MakePGDirectory(parentdir) != 0 && errno != EEXIST)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create directory \"%s\": %m", parentdir)));

	VamanaGetIndexSavePath(relid, indexdir, sizeof(indexdir));
	if (MakePGDirectory(indexdir) != 0 && errno != EEXIST)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create directory \"%s\": %m", indexdir)));
}

/*
 * Remove the on-disk save directory for a vamana index, if it exists.
 * Silently returns if the directory does not exist.
 */
void
VamanaDeleteSaveDir(Oid relid)
{
	char		indexdir[MAXPGPATH];
	struct stat st;

	VamanaGetIndexSavePath(relid, indexdir, sizeof(indexdir));

	if (stat(indexdir, &st) != 0)
		return;

	if (rmtree(indexdir, true) == false)
		ereport(WARNING,
				(errmsg("could not remove vamana index directory \"%s\"", indexdir)));
}

/*
 * Write the TID mapping for a vamana index to a sidecar file inside its
 * save directory.  The file is a VamanaTidMapHeader followed by <count>
 * ItemPointerData slots.  Uses a write-to-tmp-then-rename pattern so a crash
 * mid-write does not leave a partial file that looks valid.
 *
 * Ereports ERROR on I/O failure; caller's PG_TRY handles cleanup of the
 * entire save directory.
 */
void
VamanaSaveTidMapAtomically(Oid relid, ItemPointerData *tidMapping, int count)
{
	char		tidmappath[MAXPGPATH];
	char		tidmaptmp[MAXPGPATH];
	FILE	   *f;
	VamanaTidMapHeader header;

	snprintf(tidmappath, sizeof(tidmappath),
			 "%s/vamana_indexes/%u/tidmap.bin", DataDir, relid);
	snprintf(tidmaptmp, sizeof(tidmaptmp),
			 "%s/vamana_indexes/%u/tidmap.bin.tmp", DataDir, relid);

	f = AllocateFile(tidmaptmp, PG_BINARY_W);
	if (f == NULL)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create TID map file \"%s\": %m", tidmaptmp)));

	header.magic = VAMANA_TIDMAP_MAGIC;
	header.version = VAMANA_TIDMAP_VERSION;
	header.capacity = (uint32) count;
	header.reserved = 0;

	if (fwrite(&header, sizeof(header), 1, f) != 1 ||
		(int) fwrite(tidMapping, sizeof(ItemPointerData), count, f) != count)
	{
		FreeFile(f);
		unlink(tidmaptmp);
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not write TID map to \"%s\": %m", tidmaptmp)));
	}

	if (FreeFile(f) != 0)
	{
		unlink(tidmaptmp);
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not flush TID map file \"%s\": %m", tidmaptmp)));
	}

	if (rename(tidmaptmp, tidmappath) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not rename TID map \"%s\" to \"%s\": %m",
						tidmaptmp, tidmappath)));
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
VamanaLoadTidMap(Oid relid, ItemPointerData *tidMapping, int tidMappingCapacity)
{
	char		tidmappath[MAXPGPATH];
	FILE	   *f;
	VamanaTidMapHeader header;

	snprintf(tidmappath, sizeof(tidmappath),
			 "%s/vamana_indexes/%u/tidmap.bin", DataDir, relid);

	f = AllocateFile(tidmappath, PG_BINARY_R);
	if (f == NULL)
	{
		if (errno == ENOENT)
			return false;		/* normal "no saved file" signal */
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("could not open TID map \"%s\": %m", tidmappath)));
		return false;
	}

	if (fread(&header, sizeof(header), 1, f) != 1 ||
		header.magic != VAMANA_TIDMAP_MAGIC ||
		header.version != VAMANA_TIDMAP_VERSION ||
		header.capacity > (uint32) tidMappingCapacity)
	{
		FreeFile(f);
		ereport(WARNING,
				(errmsg("vamana index %u: TID map \"%s\" is malformed or larger "
						"than expected (%d slots), will rebuild",
						relid, tidmappath, tidMappingCapacity)));
		return false;
	}

	if (fread(tidMapping, sizeof(ItemPointerData), header.capacity, f)
		!= header.capacity)
	{
		FreeFile(f);
		ereport(WARNING,
				(errmsg("vamana index %u: TID map \"%s\" is truncated "
						"(expected %u slots), will rebuild",
						relid, tidmappath, header.capacity)));
		return false;
	}

	FreeFile(f);

	/* Slots past the persisted set are WAL-replayed inserts: mark them empty. */
	for (int i = (int) header.capacity; i < tidMappingCapacity; i++)
		ItemPointerSetInvalid(&tidMapping[i]);

	return true;
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
	GenericXLogFinish(state);
	UnlockReleaseBuffer(buf);
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

	GenericXLogFinish(state);
	UnlockReleaseBuffer(buf);
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
		VamanaEnsureSaveDir(relid);
		VamanaGetIndexSavePath(relid, savepath, sizeof(savepath));

		ereport(DEBUG1,
				(errmsg("saving vamana index for relation %u to \"%s\"", relid, savepath)));

		SVSSaveIndex(svsIndex, savepath);

		/*
		 * Build-time TID order must be preserved: a heap re-scan after VACUUM
		 * may visit tuples in different physical order and would map SVS IDs
		 * to wrong TIDs.
		 */
		if (meta->tidMapping != NULL && meta->tidMappingCapacity > 0)
			VamanaSaveTidMapAtomically(relid, meta->tidMapping, meta->tidMappingCapacity);
	}
	PG_CATCH();
	{
		VamanaDeleteSaveDir(relid);
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
