/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_vector_buffer_test.c
 *
 * SQL-callable driver for svs_vector_buffer, so pg_regress can assert on
 * it. Not part of the svs extension; never installed alongside it.
 */

#include "postgres.h"

#include "catalog/pg_type.h"
#include "funcapi.h"
#include "utils/array.h"
#include "utils/builtins.h"

#include "svs_vector_buffer.h"

PG_MODULE_MAGIC;

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_vector_buffer_test_run);
Datum
svs_vector_buffer_test_run(PG_FUNCTION_ARGS)
{
	int64		estimatedRows = PG_GETARG_INT64(0);
	int32		dimensions = PG_GETARG_INT32(1);
	ArrayType  *inputArray = PG_GETARG_ARRAYTYPE_P(2);
	Datum	   *inputDatums;
	bool	   *inputNulls;
	int			inputCount;
	int			numVectors;
	SvsVectorBuffer buf;
	Datum	   *outputDatums;
	ArrayType  *outputArray;
	TupleDesc	tupdesc;
	Datum		values[3];
	bool		nulls[3] = {false, false, false};
	HeapTuple	tuple;
	float	   *vec;

	if (dimensions <= 0)
		ereport(ERROR, (errmsg("dimensions must be positive")));

	deconstruct_array(inputArray, FLOAT8OID, 8, true, 'd',
					   &inputDatums, &inputNulls, &inputCount);

	if (inputCount % dimensions != 0)
		ereport(ERROR, (errmsg("flat_input length must be a multiple of dimensions")));

	numVectors = inputCount / dimensions;

	SvsVectorBufferInit(&buf, estimatedRows, dimensions);

	vec = palloc(dimensions * sizeof(float));
	for (int i = 0; i < numVectors; i++)
	{
		for (int j = 0; j < dimensions; j++)
			vec[j] = (float) DatumGetFloat8(inputDatums[i * dimensions + j]);
		SvsVectorBufferAppend(&buf, vec);
	}
	pfree(vec);

	outputDatums = palloc(sizeof(Datum) * buf.count * dimensions);
	for (int64 i = 0; i < buf.count * dimensions; i++)
		outputDatums[i] = Float8GetDatum((double) buf.data[i]);

	outputArray = construct_array(outputDatums, (int) (buf.count * dimensions),
								   FLOAT8OID, 8, true, 'd');

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");
	tupdesc = BlessTupleDesc(tupdesc);

	values[0] = PointerGetDatum(outputArray);
	values[1] = Int64GetDatum(buf.count);
	values[2] = Int64GetDatum(buf.capacity);

	tuple = heap_form_tuple(tupdesc, values, nulls);

	SvsVectorBufferFree(&buf);

	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}
