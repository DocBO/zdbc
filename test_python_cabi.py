#!/usr/bin/env python3
"""Comprehensive C ABI test suite for ZDBC."""
import os, sys, ctypes, tempfile, math
import numpy as np
import pandas as pd

PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))
lib_path = os.path.join(PROJECT_ROOT, "zig-out", "lib", "libzdbc.so")
if not os.path.exists(lib_path):
    import subprocess
    subprocess.run(["zig", "build", "shared"], cwd=PROJECT_ROOT, check=True)
os.environ["ZDBC_LIB"] = lib_path
sys.path.insert(0, PROJECT_ROOT)

from pyzdbc import DB
from pyzdbc._core import (
    read_column, free_column, read_table, free_table,
    COL_I64, COL_F64, COL_STR8, STR8_LEN,
    BatchTableHeader, BatchColumnMeta, BATCH_HEADER_SIZE,
)

DB_PATH = os.path.join(tempfile.gettempdir(), "zdbc_test_db")
failed = 0
passed = 0

def _s8_to_str(val):
    """Convert S8 bytes to Python str. (padding is removed in the interface)"""
    return val.decode()

def check(cond, msg):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        print(f"  FAIL: {msg}")

def section(s):
    print(f"\n── {s} ──")

# ────────────────────────────────────────────────────────
section("Setup: create DB")
db = DB(DB_PATH)

# ────────────────────────────────────────────────────────
section("1. Data integrity: write → read every value")

np.random.seed(12345)
n = 500
df = pd.DataFrame({
    "id":     np.arange(n, dtype=np.int64),
    "rand":   np.random.randint(-99999, 99999, n, dtype=np.int64),
    "score":  (np.random.randint(0, 100000, n).astype(np.float64) / 100.0),
    "code":   np.random.choice(["A", "BB", "CCC", "DDDD", "EEEEE", "FFFFFF", "GGGGGGG", "HHHHHHHH"], n),
    "active": np.random.randint(0, 2, n).astype(np.int64),
})
db.create_table("integrity", {"id": "i64", "rand": "i64", "score": "f64",
                               "code": "str", "active": "i64"})
db.write_table("integrity", df)

loaded = db.load_table("integrity")
# convert bytes columns to str for comparison with original DataFrame
for c in ["code"]:
    if c in loaded.columns:
        loaded[c] = loaded[c].apply(_s8_to_str)

for col in df.columns:
    ok = df[col].equals(loaded[col])
    check(ok, f"Column '{col}' round-trip mismatch")
    if not ok:
        mismatch = df[col] != loaded[col]
        print(f"    first mismatch at row {np.where(mismatch)[0][0]}")

check(loaded.shape == df.shape, f"shape {loaded.shape} != {df.shape}")

# ────────────────────────────────────────────────────────
section("2. Edge values: min/max/NaN/empty STR8")

df_edge = pd.DataFrame({
    "i": np.array([np.iinfo(np.int64).min, -1, 0, 1, np.iinfo(np.int64).max], dtype=np.int64),
    "f": np.array([np.nan, np.inf, -np.inf, 0.0, -0.0], dtype=np.float64),
    "s": ["", "A", "AB", "ABCDEFGH", "12345678"],
})
db.create_table("edges", {"i": "i64", "f": "f64", "s": "str"})
db.write_table("edges", df_edge)
loaded = db.load_table("edges")


check(np.array_equal(loaded["i"].values, df_edge["i"].values, equal_nan=False),
      "i64 extremes mismatch")
check(np.isnan(loaded["f"].iloc[0]), "NaN not preserved")
check(np.isinf(loaded["f"].iloc[1]) and loaded["f"].iloc[1] > 0, "+inf not preserved")
check(np.isinf(loaded["f"].iloc[2]) and loaded["f"].iloc[2] < 0, "-inf not preserved")
check(_s8_to_str(loaded["s"].iloc[0]) == "", f"empty STR8 got '{loaded['s'].iloc[0]}'")
check(_s8_to_str(loaded["s"].iloc[3]) == "ABCDEFGH", "8-char STR8 mismatch")
check(_s8_to_str(loaded["s"].iloc[4]) == "12345678", "numeric STR8 mismatch")

# ────────────────────────────────────────────────────────
section("3. Multiple tables, independence")

t1_data = pd.DataFrame({"x": np.arange(10, dtype=np.int64)})
t2_data = pd.DataFrame({"y": np.arange(100, 110, dtype=np.int64)})
t3_data = pd.DataFrame({"z": np.arange(1000, 1010, dtype=np.int64)})

db.create_table("alpha", {"x": "i64"})
db.create_table("beta",  {"y": "i64"})
db.create_table("gamma", {"z": "i64"})
db.write_table("alpha", t1_data)
db.write_table("beta",  t2_data)
db.write_table("gamma", t3_data)

for name, df_ref in [("alpha", t1_data), ("beta", t2_data), ("gamma", t3_data)]:
    loaded = db.load_table(name)
    ok = df_ref.equals(loaded)
    check(ok, f"Table '{name}' independence violated")

tables = db.list_tables()
check("alpha" in tables and "beta" in tables and "gamma" in tables,
      f"list_tables missing entries: {tables}")

ti = db.table_info("alpha")
check(ti["rows"] == 10, f"row count wrong: {ti['rows']}")

# ────────────────────────────────────────────────────────
section("4. Table sizes: 0, 1, 10000 rows")

for size, label in [(0, "zero"), (1, "one"), (10000, "tenk")]:
    tbl = f"sized_{label}"
    df_sized = pd.DataFrame({"v": np.arange(size, dtype=np.int64)})
    db.create_table(tbl, {"v": "i64"})
    db.write_table(tbl, df_sized)
    loaded = db.load_table(tbl)
    check(len(loaded) == size, f"size {label}: expected {size}, got {len(loaded)}")
    if size > 0:
        check(loaded["v"].iloc[-1] == size - 1, f"size {label}: last value mismatch")

# ────────────────────────────────────────────────────────
section("5. STR8-only table, padding test")

df_str = pd.DataFrame({"tag": ["AB", "LONGNAME", "", "XY"]})
db.create_table("str_only", {"tag": "str"})
db.write_table("str_only", df_str)
loaded = db.load_table("str_only")

check(_s8_to_str(loaded["tag"].iloc[0]) == "AB", "2-char STR8 not trimmed")
check(_s8_to_str(loaded["tag"].iloc[1]) == "LONGNAME", "8-char STR8 truncated")
check(_s8_to_str(loaded["tag"].iloc[2]) == "", "empty STR8 not preserved")

# ────────────────────────────────────────────────────────
section("6. F64-only table + precision")

df_f64 = pd.DataFrame({"val": np.array([1.23456789, -9876.54321, 0.0, math.pi, 1e300], dtype=np.float64)})
db.create_table("f64_only", {"val": "f64"})
db.write_table("f64_only", df_f64)
loaded = db.load_table("f64_only")
for i in range(len(df_f64)):
    check(math.isclose(loaded["val"].iloc[i], df_f64["val"].iloc[i], rel_tol=1e-15),
          f"f64[{i}] mismatch: {loaded['val'].iloc[i]} vs {df_f64['val'].iloc[i]}")

# ────────────────────────────────────────────────────────
section("7. read_columns with specific subsets")

df_wide = pd.DataFrame({
    "c0": np.arange(50, dtype=np.int64),
    "c1": np.arange(50, dtype=np.int64) * 2,
    "c2": np.arange(50, dtype=np.float64),
    "c3": np.random.choice(["A", "B", "C"], 50),
})
db.create_table("wide", {"c0": "i64", "c1": "i64", "c2": "f64", "c3": "str"})
db.write_table("wide", df_wide)

# Read only c0 + c2
result = db.read_columns("wide", col_names=["c0", "c2"])
check(len(result) == 2, f"subset col count: {len(result)}")
check(np.array_equal(result["c0"], df_wide["c0"].values), "subset c0 mismatch")
check(np.array_equal(result["c2"], df_wide["c2"].values, equal_nan=True), "subset c2 mismatch")

# ────────────────────────────────────────────────────────
section("8. Direct C ABI: read_column vs read_table")

data_ptr, count, col_type = read_column(db._ptr, "wide", "c0")
check(col_type == COL_I64, "C ABI col_type mismatch")
check(count == 50, f"C ABI count mismatch: {count}")

arr = np.ctypeslib.as_array(
    ctypes.cast(data_ptr, ctypes.POINTER(ctypes.c_int64)), shape=(count,)
).copy()
check(np.array_equal(arr, df_wide["c0"].values), "C ABI read_column data mismatch")

data, size = read_table(db._ptr, "wide")
check(size > 0, "C ABI read_table returned zero size")
buf = (ctypes.c_char * size).from_address(data.value or 0)
hdr = BatchTableHeader.from_buffer(buf)
check(hdr.num_rows == 50, f"batch header rows: {hdr.num_rows}")
check(hdr.num_columns == 4, f"batch header cols: {hdr.num_columns}")

metas = (BatchColumnMeta * hdr.num_columns).from_buffer(buf, BATCH_HEADER_SIZE)
names = []
for i in range(hdr.num_columns):
    meta = metas[i]
    name = meta.name.rstrip(b"\x00").decode()
    names.append(name)
    offs = meta.data_offset
    if meta.col_type == COL_I64:
        arr = np.frombuffer(buf, dtype=np.int64, count=meta.count, offset=offs)
        check(np.array_equal(arr, df_wide[name].values.astype(np.int64)),
              f"batch column '{name}' data mismatch")

# ────────────────────────────────────────────────────────
section("9. Error handling")

try:
    db.load_table("nonexistent")
    check(False, "should have raised for nonexistent table")
except Exception:
    passed += 1

try:
    db.read_column("wide", "nope")
    check(False, "should have raised for nonexistent column")
except Exception:
    passed += 1

# ────────────────────────────────────────────────────────
section("10. Drop and recreate")

db.drop_table("sized_zero")
check(not any("zero" in t or t == "sized_zero" for t in db.list_tables()),
      "dropped table still listed")

# recreate
df_new = pd.DataFrame({"v": np.array([42], dtype=np.int64)})
db.create_table("sized_zero", {"v": "i64"})
db.write_table("sized_zero", df_new)
loaded = db.load_table("sized_zero")
check(loaded["v"].iloc[0] == 42, "recreated table data mismatch")

# ────────────────────────────────────────────────────────
section("11. Raw numpy speed path (no pandas)")

import time

n = 10000
np.random.seed(99999)
df_speed = pd.DataFrame({
    "id":     np.arange(n, dtype=np.int64),
    "name":   np.random.choice(["Alice", "Bob", "Charlie", "Diana", "Eve", "Frank", "Grace", "Hank"], n),
    "score":  np.random.randint(0, 100000, n).astype(np.float64) / 100.0,
    "active": np.random.randint(0, 2, n).astype(np.int64),
    "cat":    np.random.choice(["A", "B", "C", "D"], n),
})
db.create_table("speed", {"id": "i64", "name": "str", "score": "f64",
                           "active": "i64", "cat": "str"})
db.write_table("speed", df_speed)

# 1) read_column — raw C ABI, zero-copy pointer, then .copy() to numpy
times = []
for _ in range(50):
    t0 = time.perf_counter_ns()
    data_ptr, count, col_type = read_column(db._ptr, "speed", "id")
    arr = np.ctypeslib.as_array(
        ctypes.cast(data_ptr, ctypes.POINTER(ctypes.c_int64)), shape=(count,),
    ).copy()
    free_column(db._ptr, data_ptr, count, col_type)
    times.append((time.perf_counter_ns() - t0) / 1e6)
t_read1 = np.median(times)
check(arr[0] == 0, "raw read_column i64 first value")
check(arr[-1] == n - 1, "raw read_column i64 last value")
print(f"  read_column (i64, 1 col):     {t_read1:.4f} ms")

# 2) read_column for STR8 — raw bytes
data_ptr, count, col_type = read_column(db._ptr, "speed", "name")
buf_type = ctypes.c_char * (count * STR8_LEN)
raw_bytes = bytes(buf_type.from_address(data_ptr.value or 0))
check(col_type == COL_STR8, "raw STR8 col_type")
check(len(raw_bytes) == n * STR8_LEN, f"raw STR8 len: {len(raw_bytes)}")
arr_str8 = np.frombuffer(raw_bytes, dtype=f"S{STR8_LEN}")
check(len(arr_str8) == n, f"raw STR8 count: {len(arr_str8)}")
# Verify each entry is exactly 8 bytes with valid characters
check(all(len(bytes(b)) == 8 for b in arr_str8[:100]), "STR8 row width")
free_column(db._ptr, data_ptr, count, col_type)
print(f"  STR8 raw bytes:               {STR8_LEN} bytes/row × {n} rows")

# 3) read_table — batch C ABI
times = []
for _ in range(50):
    t0 = time.perf_counter_ns()
    data, size = read_table(db._ptr, "speed")
    buf = (ctypes.c_char * size).from_address(data.value or 0)
    hdr = BatchTableHeader.from_buffer(buf)
    metas = (BatchColumnMeta * hdr.num_columns).from_buffer(buf, BATCH_HEADER_SIZE)
    results = {}
    for i in range(hdr.num_columns):
        meta = metas[i]
        offs = meta.data_offset
        if meta.col_type == COL_I64:
            results[meta.name.rstrip(b"\x00").decode()] = np.frombuffer(
                buf, dtype=np.int64, count=meta.count, offset=offs,
            ).copy()
        elif meta.col_type == COL_F64:
            results[meta.name.rstrip(b"\x00").decode()] = np.frombuffer(
                buf, dtype=np.float64, count=meta.count, offset=offs,
            ).copy()
        elif meta.col_type == COL_STR8:
            results[meta.name.rstrip(b"\x00").decode()] = np.frombuffer(
                buf, dtype=f"S{STR8_LEN}", count=meta.count, offset=offs,
            ).copy()
    free_table(db._ptr, data, size)
    times.append((time.perf_counter_ns() - t0) / 1e6)
t_batch = np.median(times)
check(np.array_equal(results["id"], df_speed["id"].values), "batch id mismatch")
check(np.array_equal(results["score"], df_speed["score"].values), "batch score mismatch")
print(f"  read_table (batch, 5 cols):   {t_batch:.4f} ms")

# ────────────────────────────────────────────────────────
# Cleanup
db.close()
import shutil
shutil.rmtree(DB_PATH + "dir", ignore_errors=True)
try: os.unlink(DB_PATH)
except OSError: pass

print(f"\n{'='*50}")
print(f"  {passed} passed, {failed} failed  ({passed+failed} total)")
print(f"{'='*50}")
sys.exit(0 if failed == 0 else 1)
