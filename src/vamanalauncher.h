/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef VAMANA_LAUNCHER_H
#define VAMANA_LAUNCHER_H

#include "postgres.h"

/* Static registration at _PG_init; counterpart to VamanaWorkerRegister(). */
void	VamanaLauncherRegister(void);

/* Launcher entry point (named in the BackgroundWorker struct). */
PGDLLEXPORT void VamanaLauncherMain(Datum main_arg);

#endif							/* VAMANA_LAUNCHER_H */
