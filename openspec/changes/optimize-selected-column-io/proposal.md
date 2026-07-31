# Change: Optimize Selected-Column I/O

## Status

Proposed

## Why

The 0.2.0 release removed major allocation and copy costs, added direct batch reads, and introduced size-aware parallel native I/O. The remaining Python selected-column path still calls `zdbc_read_column` once per requested column. Each call crosses FFI, opens and closes the data directory, allocates a Zig buffer, copies into a NumPy-owned array, and frees the Zig buffer.

The all-column batch path avoids repeated FFI and directory opens, but reads column files sequentially even when the existing native parallel path would select parallel I/O for large columns. The older optimization plan is also stale: it lists parallel I/O as deferred although 0.2.0 implemented it.

Memory mapping remains promising for large columns, but it cannot transparently replace buffered reads. `ColumnData.deinit` and `zdbc_free_sized_column` currently require allocator-owned memory, while Python immediately copies returned data. A mapped path therefore needs explicit ownership and lifetime semantics and must prove value independently.

## What Changes

1. Add a selected-column batch C ABI operation that accepts requested names and returns the existing contiguous batch layout in one FFI call.
2. Route `DB.read_columns(name, col_names=...)` through that batch operation while preserving result ordering, dtypes, errors, and independent NumPy ownership.
3. Add size-aware parallel reads directly into disjoint regions of the contiguous batch buffer for sufficiently large multi-column requests.
4. Extend benchmarks across row counts and table widths before tuning thresholds.
5. Run a separate mmap feasibility experiment for large single-column reads. Do not expose mmap as the default or alter the current free contract unless the experiment passes its performance and ownership gates.
6. Reconcile `docs/OPTIMIZATION.md` with the 0.2.0 changelog after implementation results are known.

## Expected Impact

- Selected-column reads should avoid N FFI crossings and N data-directory open/close cycles.
- Large, wide batch reads should be able to overlap independent file reads without an intermediate per-column allocation or copy.
- Existing Python callers should observe no API or dtype changes.

## Performance Gates

- For warm-cache reads of 2 to 8 selected columns, the new selected batch path must improve median latency by at least 15% in at least one representative 100,000-row or larger case.
- The new path must not regress the 10,000-row selected-column median by more than 5%.
- The all-column batch path must not regress by more than 5% at any benchmarked size.
- Parallel execution is accepted only where its median beats sequential direct-to-buffer reads; otherwise the threshold or strategy must remain sequential.
- mmap proceeds beyond an experiment only if it beats allocator-backed single-column reads by at least 15% for large columns after including Python ownership overhead.

## Impact

- Affected capability: column I/O performance.
- Expected implementation surfaces: `src/cabi.zig`, `src/ColumnIO.zig`, `pyzdbc/_core.py`, `pyzdbc/db.py`, and benchmark programs.
- On-disk format: unchanged.
- Existing public Python API: unchanged.
- New C ABI symbols: additive.

## Risks

- Parallel writes into one allocation must use non-overlapping slices and deterministic metadata offsets.
- Partial read failures must free the single batch allocation exactly once and return no partial Python result.
- Thread creation can dominate small reads, so threshold selection must be benchmark-driven.
- An mmap-backed NumPy view can outlive the database object unless ownership is attached to the returned object; this is why mmap is an explicit follow-up gate.

## Alternatives Considered

- **Always use mmap:** rejected as the first step because current deallocation semantics are allocator-specific and Python copies the data immediately.
- **Only cache the data-directory handle:** smaller change, but it does not remove repeated FFI calls, allocations, or Python conversion loops for selected columns.
- **Return borrowed arrays by default:** rejected because it changes caller-visible ownership and mutation behavior.
- **Pack schema and names first:** deferred because current profiles and code paths point to repeated selected-column calls as a more direct optimization target.
