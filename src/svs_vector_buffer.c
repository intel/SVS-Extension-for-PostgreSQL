/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#include "postgres.h"

#include "svs_memory.h"
#include "svs_vector_buffer.h"

void
SvsVectorBufferInit(SvsVectorBuffer *buf, int64 estimatedRows, int dimensions)
{
	buf->capacity = estimatedRows > 0 ? estimatedRows : SVS_VECTOR_BUFFER_DEFAULT_CAPACITY;
	buf->count = 0;
	buf->dimensions = dimensions;
	buf->data = MemoryContextAllocHuge(CurrentMemoryContext, buf->capacity * dimensions * sizeof(float));
}

void
SvsVectorBufferAppend(SvsVectorBuffer *buf, const float *vec)
{
	if (buf->count >= buf->capacity)
	{
		int64		newCapacity = buf->capacity * 2;
		uint64		newBytes = (uint64) newCapacity * buf->dimensions * sizeof(float);

		SvsMemoryCheckGrowthSize(newBytes);

		buf->capacity = newCapacity;
		buf->data = repalloc_huge(buf->data, newBytes);
	}

	memcpy(buf->data + buf->count * buf->dimensions, vec,
		   buf->dimensions * sizeof(float));
	buf->count++;
}

void
SvsVectorBufferFree(SvsVectorBuffer *buf)
{
	pfree(buf->data);
	buf->data = NULL;
	buf->count = 0;
	buf->capacity = 0;
}
