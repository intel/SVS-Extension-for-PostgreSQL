# Commenting Style Guide for pgvector-optimizations

Follow the same sparse, purposeful commenting style used in HNSW and IVFFlat. The
rule of thumb: **if the comment says the same thing as the code, delete it.**

## Do not add inline comments that restate the code

```c
/* BAD — restates what the function call already says */
/* Initialize build state */
InitBuildState(&buildstate, heap, index, indexInfo, MAIN_FORKNUM);

/* BAD — restates the condition */
/* Check for NULL query vector */
if (DatumGetPointer(so->queryValue) == NULL)

/* BAD — restates the return value */
/* Accept the insert without error */
return true;

/* GOOD — explains a non-obvious constraint */
/*
 * Use _COPY to ensure queryVec->x is in its own palloc allocation.
 * SVS reads the query vector in aligned chunks; without _COPY, an
 * untoasted datum points into the heap page buffer and SVS could read
 * past the palloc block boundary.
 */
queryVec = (Vector *) PG_DETOAST_DATUM_COPY(so->queryValue);
```

## Specific patterns to avoid

- Section-header comments before self-documenting calls: `/* Create X */` before `CreateX()`, `/* Free X */` before `pfree(x)`, `/* Build the index */` before `SVSBuildIndex()`, etc.
- Comments that repeat a function's parameter name or type: `/* Set alpha */` before `if (alpha > 0)`.
- `/* Return result */` before `return result` (or any `return` statement).
- Repeating the same comment more than once in a file.

## When an inline comment IS appropriate

- Non-obvious algorithmic choices or invariants that must hold.
- Concurrency constraints (lock ordering, barrier requirements, shared-memory visibility).
- Workarounds for bugs, platform quirks, or SVS API limitations — always include an issue number if one exists.
- Fallback strategies and their rationale (why a slow path exists).
- Cross-references to PostgreSQL internals or SVS API contracts that aren't apparent from the call site.

## Format rules

- Prefer a single-line `/* comment */` over a multi-line block for anything that fits on one line.
- Multi-line block comments (`/* ... */`) are for function headers and genuinely complex explanations only.
- Blank lines before an inline comment are fine when needed to visually separate sections; do not add a blank line purely because a comment is present.
- Do not add a blank line between a comment and the statement it annotates.
