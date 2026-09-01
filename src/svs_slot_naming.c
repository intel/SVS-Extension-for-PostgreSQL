/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_slot_naming.c
 *
 * The shared vocabulary fiction workers use to describe themselves in
 * pg_stat_activity: one bgw_type per slot kind, and the live application_name
 * each kind republishes as its granted/reserved/requested counts change.
 */

#include "postgres.h"

#include "svs_slot_naming.h"

const char *
SvsSlotKindBgwType(SvsSlotKind kind)
{
	switch (kind)
	{
		case SVS_SLOT_KIND_SEARCH:
			return "vamana search slot";
		case SVS_SLOT_KIND_BUILD:
			return "vamana build slot";
	}
	pg_unreachable();
}

void
SvsFormatSearchSlotAppName(char *buf, size_t bufsize, const char *datname,
						   int slotIndex, int slotTotal, int32 reserved)
{
	snprintf(buf, bufsize, "vamana: db=%s search slot %d/%d (reserved %d)",
			 datname, slotIndex, slotTotal, reserved);
}

void
SvsFormatBuildSlotAppName(char *buf, size_t bufsize, const char *datname,
						  int slotIndex, int slotTotal, int32 requested,
						  int32 granted)
{
	snprintf(buf, bufsize, "vamana: db=%s build slot %d/%d (requested %d, granted %d)",
			 datname, slotIndex, slotTotal, requested, granted);
}
