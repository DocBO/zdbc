# Optimization Plan

**Status:** P0-P2 IMPLEMENTED (P2.1 deferred)
**Date:** 2026-06-14
**Scope:** P0–P2 bottlenecks. P3 (mmap, name packing, schema stack buffer) postponed.

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

## P2 — Moderate (I/O parallelism, write encoding) ✓ DONE (P2.1 deferred)

### P2.1: Parallel column file I/O — DEFERRED

Requires `std.Thread` pool and careful synchronization for column file creation.
Moderate gains (~2–3× on SSD for wide tables). Deferred for future iteration.

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
