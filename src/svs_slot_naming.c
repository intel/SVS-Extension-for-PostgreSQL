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

#include "common/string.h"

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

const char *
SvsSearchSlotWaitEventName(void)
{
	return "VamanaSearchSlot";
}

/*
 * Copy datname into dst, run through core's pg_clean_ascii() first.
 * datname is chosen by anyone with CREATEDB and lands in application_name,
 * which is world-readable in pg_stat_activity and consumed by line-oriented
 * log parsers, so it must not carry a byte that could inject a line break;
 * pg_clean_ascii() is the same function core's own backend_startup.c uses
 * to sanitize application_name from a startup packet.
 *
 * dst is a fixed NAMEDATALEN buffer, but pg_clean_ascii()'s escaped output
 * can run up to 4x the length of datname, so strlcpy() here can truncate
 * mid-escape-sequence (e.g. "\x0a" cut to "\x0") for a datname that is both
 * long and control-character-heavy. That is cosmetic, not a safety issue:
 * pg_clean_ascii()'s output is pure printable ASCII by construction, so no
 * truncation point can reintroduce a raw control byte.
 */
static void
CopySanitizedDatname(char *dst, size_t dstsize, const char *datname)
{
	char	   *clean = pg_clean_ascii(datname, 0);

	strlcpy(dst, clean, dstsize);
	pfree(clean);
}

void
SvsFormatSearchSlotAppName(char *buf, size_t bufsize, const char *datname,
						   int slotIndex, int slotTotal, int32 reserved)
{
	char		safeDatname[NAMEDATALEN];

	CopySanitizedDatname(safeDatname, sizeof(safeDatname), datname);

	snprintf(buf, bufsize, "vamana: search slot %d/%d (reserved %d) db=%s",
			 slotIndex, slotTotal, reserved, safeDatname);
}

void
SvsFormatBuildSlotAppName(char *buf, size_t bufsize, const char *datname,
						  int slotIndex, int slotTotal, int32 requested,
						  int32 granted)
{
	char		safeDatname[NAMEDATALEN];

	CopySanitizedDatname(safeDatname, sizeof(safeDatname), datname);

	snprintf(buf, bufsize, "vamana: build slot %d/%d (requested %d, granted %d) db=%s",
			 slotIndex, slotTotal, requested, granted, safeDatname);
}
