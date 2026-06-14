# ZDBC

## Inspiration

This project was inspired by https://github.com/Neon32eeee/DDB.zig but re-created from scratch with strong columns-analytics focus, table separation and Pyton bindings.

## About

ZDBC is a **column-oriented embedded database** with a Zig core and Python bindings.
Each column is stored in its own binary file, enabling zero-copy reads, selective
column retrieval, and direct numpy array access from Python.

**Requirements:** Zig `0.16.0`, Linux / macOS. Python bindings require `numpy` and optionally `pandas`.

### Main Use Cases

- all kind of analytics with only 3 data types. Optimal for scientific data series of medium size, where reading speed matters.
- easy python integration
- super fast read/write of columns (huge improvement over Feather and Parquet in columns read mode)
- no incremental read/write and no database query filtering: shifted towards python pandas



## Architecture

### Column-Oriented Storage

```
DB                          # table name registry (binary)
DBdir/                       # data directory (auto-created)
  players.schema            # column names, types, row count
  players.id                # raw i64[n_rows]
  players.name              # raw u8[8 * n_rows]  (fixed 8-char, space-padded)
  players.score             # raw f64[n_rows]
```

Intermediate directories in table names are automatically created. For example,
`db.create_table("data/players", ...)` stores files under `DBdir/data/`:

Every column lives in its own file with **fixed-width binary layout**:

| Type | Zig | C ABI | Disk bytes/row | numpy dtype |
|------|-----|-------|---------------|-------------|
| Integer | `i64` | `0` | 8 | `np.int64` |
| Float | `f64` | `1` | 8 | `np.float64` |
| String | `[8]u8` (space-padded) | `2` | 8 | `S8` → decoded |

Strings are **always 8 bytes**, right-padded with spaces. This gives O(1) random
access, fixed stride per row, and direct memory mapping to numpy `S8` arrays. No
pointers, no heap indirection, no per-element parsing.

#### STR8 Padding in Python

The padding format depends on which C ABI path was used:

| Path | C function | Padding | numpy dtype | Example |
|------|-----------|---------|-------------|---------|
| `read_column()` | `zdbc_read_column` | space `0x20` (raw disk bytes) | `S8` | `b'Alice   '` |
| `read_table()` batch | `zdbc_read_table` | null `0x00` (after `trimStr8Buffer`) | `S8` | `b'Alice\x00\x00\x00'` |
| `read_columns()` default | calls `read_table` | null | `S8` | — |
| `read_columns(col_names=…)` | calls `read_column` per col | space | `S8` | — |
| `load_table()` → DataFrame | `read_columns` → `SX` | bytes columns (native SX trimmed) | `object` | `b'Alice'` |

Both paths produce valid numpy `S8` arrays. `load_table()` returns them as-is
(bytes columns in the DataFrame); call `.str.decode()` to convert to Python `str`
on demand. The raw S8 format is ~3× faster than converting to str at load time.

### Data Flow

```
Python (numpy arrays)  ⇄  libzdbc.so (C ABI)  ⇄  Disk (per-column binary files)
```

Zig is a **stateless I/O engine**: no rows stay in RAM across calls. Python owns
the data; Zig reads/writes columns on demand.

### Why Columnar?

- **Selective reads**: load only the columns you need (e.g. `id` + `score`, skip `name`)
- **Zero-copy numpy**: column files are raw binary → `np.ctypeslib.as_array()` without deserialization
- **No row objects**: no `StringHashMap` per row, no per-field type tags at runtime
- **Column pairs**: open exactly 2 files, no wasted I/O

### Recent Optimizations

The Python-to-Zig FFI path has been streamlined through seven targeted optimizations:
- **Batch column read** — all columns returned in a single FFI call (one contiguous buffer, no per-column round trips)
- **Zero-copy C ABI** — `zdbc_read_column` returns the internal data pointer directly, eliminating a Zig-side alloc+memcpy
- **Arena allocator** — transient FFI allocations use bump-pointer arenas instead of individual malloc/free
- **Direct column writes** — `zdbc_write_table` writes Python data pointers straight to disk, no intermediate ColTable allocations
- **Zig-side STR8 trim** — trailing spaces replaced with null bytes in the output buffer; numpy/pandas auto-detect null-terminated bytes, eliminating the Python string decode loop entirely
- **Vectorized string encode** — `np.char.ljust(to_numpy().astype('S8'))` replaces pandas Series chains
- **Single-column fast path** — `read_column` calls directly through the C ABI instead of routing through schema discovery

See `docs/OPTIMIZATION.md` for the detailed plan and results.

---

## Python API

### Install

```bash
zig build shared          # produces zig-out/lib/libzdbc.so
pip install numpy pandas  # required dependencies
```

```python
import pyzdbc

db = pyzdbc.DB("mydb")
```

### Schema & Write

```python
# Create table with typed columns
db.create_table("players", {
    "id":       "i64",
    "name":     "str",
    "score":    "f64",
    "active":   "i64",
    "category": "str",
})

# Write from pandas DataFrame
import pandas as pd
import numpy as np

df = pd.DataFrame({
    "id":       np.arange(10000, dtype=np.int64),
    "name":     np.random.choice(["Alice", "Bob", "Eve"], 10000),
    "score":    np.random.rand(10000) * 100,
    "active":   np.random.randint(0, 2, 10000, dtype=np.int64),
    "category": np.random.choice(["A", "B", "C"], 10000),
})
db.write_table("players", df)
```

### Read — columns first, DataFrame last

```python
# Read all columns as numpy arrays (fast path)
arrs = db.read_columns("players")
# → {"id": np.ndarray, "name": np.ndarray(S8), "score": np.ndarray, ...}

# Read a single column
ids = db.read_column("players", "id")   # → np.ndarray(dtype=int64)

# Read a pair of columns (only 2 files touched)
subset = db.read_columns("players", col_names=["id", "score"])

# Convert to DataFrame (final step — decodes S8 strings)
df = db.load_table("players")
```

### Manage Tables

```python
db.list_tables()                          # → ["players", ...]
db.table_info("players")                  # → {name, columns, rows}
db.drop_table("players")
db.close()                                # or use `with pyzdbc.DB(...) as db:`
```

### Append & Write

```python
# Load existing table, append a row, save back
df = db.load_table("players")
df.loc[len(df)] = [42, "NewGuy", 88.5, 1, "C"]
db.write_table("players", df)
```

For large tables where full load/write is expensive, work with numpy columns directly:

```python
# Read columns as numpy arrays
cols = db.read_columns("players", col_names=["id", "name", "score"])

# Append one row of values
cols["id"]    = np.append(cols["id"], [99])
cols["name"]  = np.append(cols["name"], np.array(["Extra"], dtype="S8"))
cols["score"] = np.append(cols["score"], [77.7])

# Write back with a DataFrame (pass the rest unchanged)
import pandas as pd
df = db.load_table("players")              # get full table
for c, arr in cols.items():                # overwrite modified columns
    df[c] = arr if arr.dtype.kind != "S" else arr.astype(str).str.strip()
db.write_table("players", df)
```

> **Note:** A native append-row C ABI (writing directly to column files without a full rewrite) is planned. For now, the load→modify→write pattern above works for all table sizes.

---

## Zig API

```zig
const ddb = @import("ddb");

var db = try ddb.DB().init("mydb", allocator);
defer db.deinit();

// Create table
const col_defs = [_]ddb.ColumnSchema{
    .{ .name = "id",    .col_type = .I64 },
    .{ .name = "name",  .col_type = .STR8 },
    .{ .name = "score", .col_type = .F64 },
};
try db.createTable("players", &col_defs);

// Build a ColTable in memory
var table = try ddb.Table.init(schema, allocator);
defer table.deinit();
try table.setI64("id", 0, 1);
try table.setStr8("name", 0, "Jon");
try table.setF64("score", 0, 100.5);

// Save to disk (per-column files)
try db.saveColTable("players", &table);

// Read individual columns from disk
var id_col = try db.readColumn("players", "id");
defer id_col.deinit(allocator);
// id_col.I64[0] == 1

// Read a pair of columns
const pair_names = [_][]const u8{ "name", "score" };
var pair = try db.readColumns("players", &pair_names);

// Load full table
var loaded = try db.loadColTable("players");
defer loaded.deinit();

// Columnar aggregation (fast)
const ids = loaded.columns[0].I64;
var sum: i64 = 0;
for (ids) |v| sum += v;
```

---

## Benchmarks

**Setup:** 10,000 rows × 5 columns (id:i64, name:str, score:f64, active:i64, category:str)
on AMD Ryzen, Linux, NVMe SSD.

### Zig Native (`zig build col_perf`, ReleaseFast)

| Phase | Time | Notes |
|-------|------|-------|
| Generate (in RAM) | 0.82 ms | 82 ns/row |
| Save (5 column files) | 7.86 ms | 40.0 B/row on disk |
| Read 1 column | 0.10 ms | single 80 KB file |
| Read 2 columns | 0.16 ms | 160 KB total |
| Load full table | 0.33 ms | all 5 columns, 400 KB |
| Aggregate 3 columns | 0.03 ms | sum id+score+active |

**Disk layout:** 400 KB total (registry 13 B + schema 62 B + 5×80 KB column files).

### Python I/O: pyzdbc vs Feather vs Parquet

| Format | Disk | Write | Read (median of 5) | vs baseline |
|--------|------|-------|---------------------|-------------|
| **pyzdbc** | 390.7 KB | 8.05 ms | **0.28 ms** | **7.2× faster read vs Feather** |
| Feather | 204.7 KB | 9.00 ms | 2.01 ms | — |
| Parquet (uncompressed) | 171.1 KB | 5.57 ms | 2.40 ms | — |
| Parquet (snappy) | 110.1 KB | 17.98 ms | 2.89 ms | — |

- **Reads**: pyzdbc is **7× faster** than Feather, **10× faster** than compressed Parquet.
- **Writes**: pyzdbc is competitive with Feather, behind uncompressed Parquet (per-column file overhead).
- **`load_table` (→DataFrame)**: **1.69 ms** — STR8 columns returned as `bytes`; call `.str.decode()` to convert to str.
- **Disk**: 40.0 B/row (fixed 8-byte strings); 2–3× larger than compressed formats — tradeoff for fixed-stride zero-copy access.

### Python Throughput (current)

| Metric | Time |
|--------|------|
| `write_table` | 8.05 ms |
| `read_columns` (all cols) | 0.28 ms |
| `read_column` (single) | 0.03 ms |
| `load_table` (→DataFrame) | 1.69 ms |

Run benchmarks:
```bash
zig build col_perf                            # Zig native
python examples/benchmarks/bench_column.py    # Python comparison
```

---

## Commands

```bash
zig build              # static library
zig build shared       # libzdbc.so (Python)
zig build test         # all tests
zig build run          # CLI example
zig build col_perf     # column benchmark
```

### Testing

**Zig unit tests** (30 tests, in `src/`):
- ColTable: init/lazy, STR8 padding/trimming, edge values (i64 min/max, f64 NaN/±inf),
  type mismatch errors, out-of-bounds access
- ColumnIO: schema read/write, column file round-trip, read-into-buffer, parallel
  read/write with auto-detection threshold, 0/1-column edge cases, not-found errors,
  0-row tables
- root.zig: init/deinit, create/drop/list tables, save/load round-trip, parallel
  variants, read specific column subsets, multi-table independence, 20-column wide
  tables, 0/1-row edge cases

**Python C ABI tests** (54 tests, `test_python_cabi.py`):
- Data integrity: write → read every value for I64, F64, STR8 columns
- Edge values: i64 min/max, f64 NaN/±inf/±0, STR8 empty/8-char
- Multi-table isolation, drop-and-recreate, 0/1/10k row sizes
- STR8 padding round-trip, F64 precision (1e-15 rel_tol)
- `read_column` raw numpy path vs `read_table` batch path vs `read_columns` subset
- Raw speed test: direct C ABI → numpy (no pandas), measuring pure I/O latency
- Error handling: non-existent tables, non-existent columns

```bash
zig build test                        # Zig: 30 tests
python test_python_cabi.py            # Python: 54 tests
```
