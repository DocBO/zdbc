# Column-Oriented Architecture — Architecture Document

**Status:** IMPLEMENTED
**Date:** 2026-06-14

## 1. Architecture Overview

### 1.1 Storage Layout

```
DB                     # table name registry (binary)
DBdir/
  players.schema       # column names, types, row count
  players.id           # binary: i64[n_rows]
  players.name         # binary: u8[8 * n_rows] (fixed 8-char, space-padded)
  players.score        # binary: f64[n_rows]
```

Each column is stored in its own file. Schema file defines layout. No row-based storage.

### 1.2 Key Types

| Type | File | Role |
|------|------|------|
| `ColType` | `ColTable.zig` | Enum: `I64`, `F64`, `STR8` |
| `ColumnSchema` | `ColTable.zig` | `{ name: []const u8, col_type: ColType }` |
| `TableSchema` | `ColTable.zig` | `{ name, columns: []ColumnSchema, num_rows }` |
| `ColumnData` | `ColTable.zig` | Union: `I64([]i64)`, `F64([]f64)`, `STR8([][8]u8)` |
| `ColTable` | `ColTable.zig` | Column-oriented table: `{ schema, columns: []ColumnData }` |
| `DB` | `root.zig` | Registry: `schemas: StringHashMap(TableSchema)`, stateless I/O |

### 1.3 String Convention

All string fields are fixed 8 bytes, right-padded with spaces. This enables:
- Fixed-stride column files (no parsing overhead)
- Direct numpy `S8` dtype mapping
- O(1) random access by row index

### 1.4 Data Flow (Python)

```
Python (numpy arrays) → Zig (ColumnData) → Disk (per-column binary files)
```

No rows are held in Zig RAM across calls. The DB struct is just a thin schema registry.
All data I/O is on-demand per column or per table.

## 2. C ABI

```
zdbc_init(path) → *DB
zdbc_deinit(*DB)
zdbc_create_table(*DB, name, col_names[], col_types[], n)
zdbc_drop_table(*DB, name)
zdbc_list_tables(*DB, out_buf, buf_len)
zdbc_table_row_count(*DB, name) → i64
zdbc_table_column_count(*DB, name) → i32
zdbc_table_column_info(*DB, name, idx, out_name, out_len, *out_type)
zdbc_read_column(*DB, table, col, *out_data, *out_count, *out_type)
zdbc_free_sized_column(*DB, data, count, col_type)
zdbc_write_table(*DB, name, col_names[], col_types[], n_cols, col_data[], n_rows)
```

Type codes: 0=I64, 1=F64, 2=STR8. STR8 data is `char[n_rows * 8]`.

## 3. Python API

```python
import pyzdbc

db = pyzdbc.DB("mydb")

# Create table schema
db.create_table("players", {"id": "i64", "name": "str", "score": "f64"})

# Read columns directly as numpy arrays
arrs = db.read_columns("players")  # {"id": np.ndarray, "name": np.ndarray, ...}
hp = db.read_column("players", "id")  # single column as np.ndarray

# Convert to DataFrame (final step)
df = db.load_table("players")

# Write from DataFrame
db.write_table("players", df)
```

## 4. File Format

### Schema file (`<name>.schema`)
```
[num_rows: u64]
[num_columns: u32]
for each column:
  [name_len: u32][name: bytes][col_type: u8]
```

### Column files (`<name>.<col>`)
- I64: raw `[n_rows]i64` little-endian
- F64: raw `[n_rows]f64` little-endian
- STR8: raw `[n_rows * 8]u8` — each 8-byte chunk is one space-padded string
