# ZDBC

## Inspiration

This project was inspired by https://github.com/Neon32eeee/DDB.zig but re-created from scratch with string analytics focus, table separation and Pyton bindings.

## About

ZDBC is a **column-oriented embedded database** with a Zig core and Python bindings.
Each column is stored in its own binary file, enabling zero-copy reads, selective
column retrieval, and direct numpy array access from Python.

**Requirements:** Zig `0.15.1`, Linux / macOS. Python bindings require `numpy` and optionally `pandas`.

## Architecture

### Column-Oriented Storage

```
DB                          # table name registry (binary)
DBdir/
  players.schema            # column names, types, row count
  players.id                # raw i64[n_rows]
  players.name              # raw u8[8 * n_rows]  (fixed 8-char, space-padded)
  players.score             # raw f64[n_rows]
```

Every column lives in its own file with **fixed-width binary layout**:

| Type | Zig | C ABI | Disk bytes/row | numpy dtype |
|------|-----|-------|---------------|-------------|
| Integer | `i64` | `0` | 8 | `np.int64` |
| Float | `f64` | `1` | 8 | `np.float64` |
| String | `[8]u8` (space-padded) | `2` | 8 | `S8` → decoded |

Strings are **always 8 bytes**, right-padded with spaces. This gives O(1) random
access, fixed stride per row, and direct memory mapping to numpy `S8` arrays. No
pointers, no heap indirection, no per-element parsing.

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
| Generate (in RAM) | 0.75 ms | 75 ns/row |
| Save (5 column files) | 0.98 ms | 40.0 B/row on disk |
| Read 1 column | 0.10 ms | single 80 KB file |
| Read 2 columns | 0.22 ms | 160 KB total |
| Load full table | 0.48 ms | all 5 columns, 400 KB |
| Aggregate 3 columns | 0.03 ms | sum id+score+active |

**Disk layout:** 400 KB total (registry 13 B + schema 62 B + 5×80 KB column files).

### Python I/O: pyzdbc vs Feather vs Parquet

| Format | Disk | Write | Read (median of 5) | vs baseline |
|--------|------|-------|---------------------|-------------|
| **pyzdbc** | 390.7 KB | 8.6 ms | **0.33 ms** | **5.8× faster read vs Feather** |
| Feather | 204.7 KB | 8.7 ms | 1.9 ms | — |
| Parquet (uncompressed) | 171.1 KB | 7.1 ms | 2.6 ms | — |
| Parquet (snappy) | 110.1 KB | 21.0 ms | 3.5 ms | — |

- **Reads**: pyzdbc is **6× faster** than Feather, **10× faster** than compressed Parquet.
- **Writes**: pyzdbc is competitive with Feather, slightly behind uncompressed Parquet (per-column file overhead).
- **`load_table` (→DataFrame)**: **1.77 ms** — faster than Feather's raw read (1.92 ms).
- **Disk**: 40.0 B/row (fixed 8-byte strings); 2–3× larger than compressed formats — tradeoff for fixed-stride zero-copy access.

### Before/After Optimization

| Python Metric | Before | After | Improvement |
|---------------|--------|-------|-------------|
| `read_columns` (all cols) | 0.40 ms | **0.33 ms** | 1.2× faster |
| `read_column` (single) | 0.05 ms | 0.03 ms | 1.5× faster |
| `load_table` (→DataFrame) | 7.74 ms | **1.77 ms** | **4.4× faster** |
| `write_table` | 10.17 ms | **8.58 ms** | 1.2× faster |

Run benchmarks:
```bash
zig build col_perf                            # Zig native
python examples/benchmarks/bench_column.py    # Python comparison
```

---

## Installation (Zig Package)

```bash
zig fetch --save https://github.com/Neon32eeee/ZDBC.zig/archive/refs/heads/main.tar.gz
```

`build.zig`:
```zig
const ddb = b.dependency("ddb", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ddb", ddb.module("ddb"));
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
