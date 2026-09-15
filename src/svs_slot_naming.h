/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef SVS_SLOT_NAMING_H
#define SVS_SLOT_NAMING_H

#include "postgres.h"

typedef enum SvsSlotKind
{
	SVS_SLOT_KIND_SEARCH,
	SVS_SLOT_KIND_BUILD
} SvsSlotKind;

/* Fixed bgw_type/backend_type label for a fiction worker of this kind. */
extern const char *SvsSlotKindBgwType(SvsSlotKind kind);

/*
 * application_name for a search slot, set via pgstat_report_appname() from
 * inside the running fiction worker.  Called again whenever granted/reserved
 * change, since neither is fixed for the slot's lifetime.  Format is
 * "vamana: search slot %d/%d (reserved %d) db=%s"; the counts come first so
 * NAMEDATALEN truncation costs datname rather than the counts, and datname
 * is sanitized so a control character in it cannot reach application_name.
 */
extern void SvsFormatSearchSlotAppName(char *buf, size_t bufsize,
										const char *datname, int slotIndex,
										int slotTotal, int32 reserved);

/*
 * application_name for a build slot, set once the launcher answers the
 * grant request.  Format is
 * "vamana: build slot %d/%d (requested %d, granted %d) db=%s", with the
 * same counts-first ordering and datname sanitizing as the search slot
 * formatter.
 */
extern void SvsFormatBuildSlotAppName(char *buf, size_t bufsize,
									   const char *datname, int slotIndex,
									   int slotTotal, int32 requested,
									   int32 granted);

#endif							/* SVS_SLOT_NAMING_H */
