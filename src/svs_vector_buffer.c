/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#include "postgres.h"

#include "svs_vector_buffer.h"

void
SvsVectorBufferInit(SvsVectorBuffer *buf, int64 estimatedRows, int dimensions)
{
	buf->capacity = estimatedRows > 0 ? estimatedRows : SVS_VECTOR_BUFFER_DEFAULT_CAPACITY;
	buf->count = 0;
	buf->dimensions = dimensions;
	buf->data = palloc(buf->capacity * dimensions * sizeof(float));
}

void
SvsVectorBufferAppend(SvsVectorBuffer *buf, const float *vec)
{
	if (buf->count >= buf->capacity)
	{
		buf->capacity *= 2;
		buf->data = repalloc(buf->data,
							  buf->capacity * buf->dimensions * sizeof(float));
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
