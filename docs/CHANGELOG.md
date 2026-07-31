# CHANGELOG

### PHASE 3 IN PROGRESS: Selected-Column Batch I/O

**Status**: CANDIDATE IMPLEMENTED, DEFAULT ENABLEMENT REJECTED
**Date Started**: July 31, 2026
**Focus**: Remove repeated FFI and directory-open overhead from selected-column reads

#### Phase 3 Progress:

- Added an additive selected-column batch C ABI using the existing contiguous batch layout.
- Added direct-to-final-buffer reads and preserved independent NumPy ownership.
- Added a selected-column benchmark matrix covering 10k to 1m rows and 1 to 20 columns.
- Parallel benchmarking showed the candidate 0.8% to 444% slower than repeated reads in measured 100k and 1m-row cases.
- Sequential 100k-row benchmarking improved one-column latency by 37%, but regressed 2-column latency by 10% and wider requests by 67% to 330%.
- Kept the existing Python selected-column path and sequential batch I/O as required by the performance gate.

## [0.2.0] — 2026-06-14

### Zig 0.16.0 Migration

- Bumped minimum Zig version from `0.15.1` to **`0.16.0`** (`build.zig.zon`).
- Replaced `std.fs` blocking-I/O API with the new `std.Io` subsystem. All `Dir`/`File`
  operations now take an explicit `io: Io` parameter via vtable dispatch.
- `std.fs.cwd()` → `std.Io.Dir.cwd()`, `file.writer(buffer)` → `std.fmt.bufPrint` based
  serialization + `file.writeStreamingAll(io, ...)`, `file.reader(buffer)` →
  `file.readPositionalAll(io, ...)`.
- `linkLibC()` removed → `root_module.link_libc = true` (`build.zig`).
- `std.mem.trimRight` → `std.mem.trimEnd`, `std.ArrayList` init → `.empty` sentinel,
  `std.time.Timer` → `Io.Timestamp.now(io, .awake)`.
- Added module-level `global_io` backed by `Io.Threaded.init_single_threaded` for
  synchronous C ABI paths.

### Performance

**I/O path overhaul:**

| Optimization | What | Impact |
|---|---|---|
| `ColTable.initLazy` | Skip pre-allocation of column arrays when loading from disk | LOAD **3× faster** (0.98 → 0.33 ms) |
| Stack-allocated file names | `bufPrint` into 256-byte stack buffer instead of `std.mem.concat` heap alloc | SAVE **5× faster** (8.2 → 1.8 ms) |
| `readColumnFileIntoBuf` | Read column data directly into caller-provided buffer, skipping alloc+copy | Batch `zdbc_read_table` 3.5× faster |
| `ensureDataDir` cache | `data_dir_ensured` flag skips `mkdirat`+`lstat` on subsequent calls | ~16% per-call improvement |
| `trimStr8Buffer` fast-path | Replaced byte-by-byte scan with single `u64` XOR+`@clz`+masked store; removed trim from `zdbc_read_column` (Python handles S8→str natively) | STR8 columns **20× faster** (0.35 → 0.02 ms) |

**Parallel I/O:**

- `loadColTableParallel` / `readColumnFilesParallel` — thread-per-column reads with
  auto-detection: below ~100 KB per column (~12,500 rows) falls back to sequential.
- `saveColTableParallel` / `writeColumnFilesParallel` — same pattern for writes.
  Write parallelism mainly benefits the warm cache path; cold writes are bottlenecked
  by filesystem block allocation.
- `updateRegistryEntry` helper extracted to DRY schema registry updates across
  `saveColTable`, `saveColTableParallel`, and `saveTableSchema`.

### Python C ABI

- `zdbc_read_table` rewritten to read all columns directly into a single contiguous
  output buffer (`readColumnFileIntoBuf`), eliminating per-column alloc+copy+free.
  Eliminated per-column `openDir`/`closeDir` that `db.readColumn` was performing.
- `zdbc_read_column` STR8 trim removed — Python/numpy decode trailing spaces natively,
  saving ~0.3 ms per STR8 column.
- `zdbc_free_column` fixed for Zig 0.16.0 slice semantics.

### Benchmark Results

**Zig Native** (`zig build col_perf`, ReleaseFast, 10k rows × 5 cols warm cache):

| Phase | Time |
|-------|------|
| Generate | 0.72 ms |
| Load full table | 0.33 ms |
| Read 1 column | 0.07 ms |
| Aggregate 3 columns | 0.03 ms |

**Python** (`bench_column.py`, vs Feather/Parquet):

| Format | Read (5 cols) |
|--------|---------------|
| **pyzdbc** | **0.40 ms** |
| Feather | 1.59 ms |
| Parquet (snappy) | 3.10 ms |

pyzdbc reads are **4× faster** than Feather, **8× faster** than compressed Parquet.
`load_table` (→DataFrame): 1.85 ms.

### Library API

| Function | Description |
|----------|-------------|
| `loadColTableParallel` | Parallel column reads with auto-detection |
| `saveColTableParallel` | Parallel column writes with auto-detection |
| `readColumnFilesParallel` | Raw parallel reads into pre-allocated `[]ColumnData` |
| `writeColumnFilesParallel` | Raw parallel writes from `[]ColumnData` |
| `readColumnFileIntoBuf` | Read a single column file directly into a caller buffer |
| `ColTable.initLazy` | Create table without pre-allocating column arrays |

