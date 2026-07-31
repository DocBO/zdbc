# Optimization Plan

**Status:** P0-P2 IMPLEMENTED; P3 CANDIDATE REJECTED FOR DEFAULT ENABLEMENT
**Date:** 2026-07-31
**Scope:** P0–P3 I/O bottlenecks. mmap remains gated on ownership-safe benchmark results.

## Results Summary (10k rows × 5 columns)

| Metric | Baseline | After | Improvement |
|--------|----------|-------|-------------|
| `read_columns` (batch) | 0.40 ms | **0.25 ms** | 38% faster |
| `load_table` (→DataFrame) | 7.74 ms | **4.92 ms** | 36% faster |
| `write_table` | 10.17 ms | **8.27 ms** | 19% faster |
| Zig native save | 0.98 ms | unchanged | — |
| Zig native full load | 0.48 ms | unchanged | — |

pyzdbc reads now **8× faster** than Feather, **12× faster** than compressed Parquet.

---

## P0 — Critical (Python latency, ~8ms → ~5ms) ✓ DONE

### P0.1: Batch column read — single FFI call for all columns ✓

**Status:** DONE. Added `zdbc_read_table` C ABI function (`src/cabi.zig:177`). Zig reads all columns into one contiguous buffer:
```zig
[BatchTableHeader(16) | BatchColumnMeta[N]×64 | col0 data | col1 data | ...]
```
Python calls `_core.read_table()` (1 FFI call), parses the flat buffer with ctypes structs,
creates numpy arrays from offsets. Freed with `_core.free_table()`.

### P0.2: Vectorized STR8 decoding ✓

**Status:** DONE. Replaced Python list comprehension:
```python
# Before:
np.array([s.decode("utf-8").rstrip() for s in arr])
# After:
arr.astype("<U8"); np.char.rstrip(arr)
```
2.2× faster per column (~1.2 ms saved). `load_table` dropped from 7.7 → 5.8 ms.

---

## P1 — Significant (Zig alloc/memcpy elimination) ✓ DONE

### P1.1: Eliminate double-copy in `zdbc_read_column` ✓

**Status:** DONE. `zdbc_read_column` now returns ColumnData's internal pointer directly
(via `col_data.ptr()`), bypassing the intermediate `alloc + memcpy` buffer.
Python still copies into numpy (unavoidable) but Zig-internal waste eliminated.

### P1.2: Eliminate intermediate ColTable in `zdbc_write_table` ✓

**Status:** DONE. `zdbc_write_table` writes column files directly from Python's data
pointers to disk files. No `ColTable.init` + `@memcpy` + `table.deinit` cycle.
Schema is persisted via new `db.saveTableSchema()` method.

### P1.3: Arena allocator for FFI request scope ✓

**Status:** DONE. Added `newArena()` helper backed by `c_allocator`. Used in
`zdbc_create_table`, `zdbc_write_table` for transient allocations.
`zdbc_read_column` keeps `db.allocator` for the returned buffer (async lifetime).

---

## P2 — Moderate (I/O parallelism, write encoding) ✓ DONE

### P2.1: Parallel column file I/O ✓

**Status:** DONE in 0.2.0. Native reads and writes use thread-per-column I/O above
the measured ~100 KB per-column threshold and sequential I/O below it.

### P2.2: Vectorized STR8 encoding on write ✓

**Status:** DONE. Replaced pandas Series chain with numpy direct:
```python
# Before:
s = df[col_name].astype(str).str.slice(0, 8).str.pad(8, side="right")
arr = np.array(padded, dtype="S8")
# After:
raw = df[col_name].to_numpy(dtype=str)
arr = np.char.ljust(raw.astype(f"S{STR8_LEN}"), STR8_LEN)
```

### P2.3: Direct single-column read without schema discovery ✓

**Status:** DONE. `db.read_column(name, col)` now calls `_core.read_column()` directly
(1 FFI call) instead of going through `read_columns()` (N+1 FFI calls).

---

## Implementation Order

1. **P1.3** — Arena allocator (foundation for P0.1 and P1.1)
2. **P0.1** — Batch column read C ABI (biggest Python impact)
3. **P1.1** — Eliminate double-copy in read (cleanup enabled by P1.3)
4. **P0.2** — Vectorized STR8 decoding
5. **P1.2** — Eliminate intermediate ColTable on write
6. **P2.1** — Parallel column I/O
7. **P2.2** — Vectorized STR8 encoding
8. **P2.3** — Direct single-column read

P0.2 and P0.1 together should bring `load_table` from 7.7 ms to ~1 ms for 10k rows.

---

## P3 — Selected-Column Batch I/O — CANDIDATE RETAINED, DEFAULT REJECTED

### P3.1: Single FFI request for selected columns ✓

Added `zdbc_read_columns`, which validates requested names and returns only those
columns in the existing contiguous batch layout. The symbol remains additive for
experimentation, but Python retains repeated `zdbc_read_column` calls because the
candidate missed its performance gate.

### P3.2: Adaptive direct-to-buffer reads ✓

Selected and all-column batch reads target final non-overlapping output slices.
Parallel direct-to-buffer reads were tested and rejected; batch reads remain
sequential because the threaded path regressed measured latency.

### P3.3: Benchmark matrix ✓

`examples/benchmarks/bench_selected.py` compares selected batches with repeated
single-column reads for 10k, 100k, and 1m rows across 1, 2, 5, 8, and 20 columns.
The parallel candidate was 61% to 444% slower at 100k rows and 0.8% to 70% slower
at 1m rows. Sequential direct-to-buffer reads improved the 100k-row one-column case
by 37%, but regressed 2 columns by 10% and 5 to 20 columns by 67% to 330%. The
public selected-column path therefore remains unchanged. The benchmark is retained
to re-evaluate future implementations; profiling should focus on batch parsing and
the second Python-owned copy before another enablement attempt.

### P3.4: mmap — GATED

mmap is not part of the default path. It requires a separate owner that can safely
unmap after NumPy releases the view and must beat allocator-backed reads by at least
15% end to end before a public API is proposed.
