/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef SVS_VECTOR_BUFFER_H
#define SVS_VECTOR_BUFFER_H

#include "postgres.h"

#define SVS_VECTOR_BUFFER_DEFAULT_CAPACITY 1000

/*
 * Holds every vector of a build in one flat array, which routinely exceeds
 * MaxAllocSize; allocated and grown through the huge-allocation API rather
 * than plain palloc/repalloc.
 */
typedef struct SvsVectorBuffer
{
	float	   *data;
	int64		count;
	int64		capacity;
	int			dimensions;
}			SvsVectorBuffer;

extern void SvsVectorBufferInit(SvsVectorBuffer *buf, int64 estimatedRows, int dimensions);
extern void SvsVectorBufferAppend(SvsVectorBuffer *buf, const float *vec);
extern void SvsVectorBufferFree(SvsVectorBuffer *buf);

#endif							/* SVS_VECTOR_BUFFER_H */
