# Design: Selected-Column Batch Reads

## Current Flow

For `DB.read_columns(name, col_names=[...])`, Python loops over names. Every iteration calls `zdbc_read_column`, and the Zig database opens the data directory, reads one allocator-owned column, returns its pointer, and closes the directory. Python then copies the data and calls `zdbc_free_sized_column`.

For all columns, `zdbc_read_table` opens the directory once and reads directly into one contiguous allocation, but it processes files sequentially.

## Proposed Flow

Add an additive C ABI entry point for selected columns. It validates all requested names against the in-memory schema, computes metadata and aligned data offsets, allocates one output buffer, and opens the data directory once. Each requested file is read directly into its final output slice.

The returned layout remains compatible with the existing batch parser:

```text
BatchTableHeader | BatchColumnMeta[N] | selected column bytes
```

Python parses the response with the existing batch machinery and copies each array into NumPy-owned memory before freeing the batch allocation. This preserves current ownership semantics while removing repeated crossings and temporary column allocations.

## Parallel Strategy

Parallel work is eligible only when at least two columns are requested and per-column bytes exceed a benchmark-selected threshold. Jobs receive disjoint output slices and immutable schema/name data. The caller joins every started thread before freeing or returning the batch buffer.

The initial implementation may reuse the existing thread-per-column strategy. A bounded worker design is preferred only if benchmarks show excessive thread overhead for wide tables.

## Failure Semantics

- Validate all requested columns before allocation or I/O.
- Reject duplicate names only if the current Python dictionary result cannot represent them consistently; otherwise document first-position metadata and last-value dictionary behavior before implementation.
- On any open, read, or size error, join started threads, free the batch allocation once, and return the existing mapped error code.
- Never return a partially initialized batch result.

## mmap Experiment

The experiment must use a distinct mapped-buffer owner rather than `ColumnData`. It must define unmap behavior, file-descriptor lifetime, database-close behavior, and NumPy base-object ownership. Benchmark both direct Zig access and end-to-end Python access. If Python must copy before return, compare mmap-plus-copy against the existing positional-read-plus-copy path.

No public mmap API is part of this change unless the feasibility task is explicitly approved after benchmark review.
