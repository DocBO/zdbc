#!/usr/bin/env python3
"""Benchmark: pyzdbc column I/O vs Feather vs Parquet — 10k rows x 5 columns."""

import sys
import os
import time
import subprocess
import tempfile
import numpy as np
import pandas as pd

PROJECT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")

# ── Locate libzdbc.so ───────────────────────────────────────────────────
lib_path = os.path.join(PROJECT_ROOT, "zig-out", "lib", "libzdbc.so")
if not os.path.exists(lib_path):
    print("Building libzdbc.so...")
    subprocess.run(["zig", "build", "shared"], cwd=PROJECT_ROOT, check=True)

os.environ["ZDBC_LIB"] = lib_path
sys.path.insert(0, PROJECT_ROOT)

from pyzdbc import DB


def ms(elapsed_sec):
    return f"{elapsed_sec * 1000:8.3f} ms"


def size_fmt(b):
    if b < 1024:
        return f"{b} B"
    return f"{b / 1024:.1f} KB"


# ── Generate test data (same seed as zig benchmark) ────────────────────
SEED = 42
NUM_ROWS = 10000
np.random.seed(SEED)

names = np.array(["Alice", "Bob", "Charlie", "Diana", "Eve", "Frank", "Grace", "Hank"])
categories = np.array(["A", "B", "C", "D"])

df_orig = pd.DataFrame({
    "id": np.arange(NUM_ROWS, dtype=np.int64),
    "name": np.random.choice(names, NUM_ROWS),
    "score": np.random.randint(0, 10000, NUM_ROWS).astype(np.float64) / 10.0,
    "active": np.random.randint(0, 2, NUM_ROWS).astype(np.int64),
    "category": np.random.choice(categories, NUM_ROWS),
})

mem = df_orig.memory_usage(deep=True).sum()
print("=" * 62)
print("  PYTHON BENCHMARK — pyzdbc vs Feather vs Parquet")
print("  {} rows x {} columns  ({})".format(NUM_ROWS, len(df_orig.columns), size_fmt(int(mem))))
print("=" * 62)

# ── 1. pyzdbc: Write & Read ─────────────────────────────────────────────
print("\n── pyzdbc (column-oriented binary) ──")

DB_PATH = os.path.join(tempfile.gettempdir(), "pybench")

# Write
db = DB(DB_PATH)
db.create_table("bench", {"id": "i64", "name": "str", "score": "f64",
                           "active": "i64", "category": "str"})

t0 = time.perf_counter()
db.write_table("bench", df_orig)
t_write_zdbc = time.perf_counter() - t0

def dir_size(path):
    total = 0
    for root, dirs, files in os.walk(path):
        for f in files:
            total += os.path.getsize(os.path.join(root, f))
    return total

zdbc_disk = dir_size(DB_PATH + "dir") + os.path.getsize(DB_PATH)
print(f"  Write:           {ms(t_write_zdbc)}")
print(f"  Disk:            {size_fmt(zdbc_disk)}  ({zdbc_disk / len(df_orig):.1f} B/row)")

# Read all columns (numpy arrays only, no DataFrame yet)
runs = 5
times = []
for _ in range(runs):
    t0 = time.perf_counter()
    arrs = db.read_columns("bench")
    times.append(time.perf_counter() - t0)
t_read_cols = sorted(times)[len(times) // 2]
print(f"  read_columns() x{runs}: {ms(t_read_cols)} median")

# Read single column
times = []
for _ in range(runs):
    t0 = time.perf_counter()
    col = db.read_column("bench", "id")
    times.append(time.perf_counter() - t0)
t_read_one = sorted(times)[len(times) // 2]
print(f"  read_column() x{runs}:  {ms(t_read_one)} median")

# Convert to DataFrame (final step)
t0 = time.perf_counter()
df_zdbc = db.load_table("bench")
t_load_zdbc = time.perf_counter() - t0
print(f"  load_table() (->DF):{ms(t_load_zdbc)}")
db.close()

# ── 2. Feather ─────────────────────────────────────────────────────────
print("\n── Feather (arrow::feather) ──")

feather_path = os.path.join(tempfile.gettempdir(), "pybench.feather")

t0 = time.perf_counter()
df_orig.to_feather(feather_path)
t_write_f = time.perf_counter() - t0

f_size = os.path.getsize(feather_path)
print(f"  Write:             {ms(t_write_f)}")
print(f"  Disk:              {size_fmt(f_size)}  ({f_size / len(df_orig):.1f} B/row)")

times = []
for _ in range(runs):
    t0 = time.perf_counter()
    df = pd.read_feather(feather_path)
    times.append(time.perf_counter() - t0)
t_read_f = sorted(times)[len(times) // 2]
print(f"  Read x{runs}:           {ms(t_read_f)} median")
os.unlink(feather_path)

# ── 3. Parquet ─────────────────────────────────────────────────────────
print("\n── Parquet (arrow::parquet) ──")

parquet_path = os.path.join(tempfile.gettempdir(), "pybench.parquet")

t0 = time.perf_counter()
df_orig.to_parquet(parquet_path, engine="pyarrow", compression="snappy")
t_write_p = time.perf_counter() - t0

p_size = os.path.getsize(parquet_path)
print(f"  Write:             {ms(t_write_p)}")
print(f"  Disk:              {size_fmt(p_size)}  ({p_size / len(df_orig):.1f} B/row)")

times = []
for _ in range(runs):
    t0 = time.perf_counter()
    df = pd.read_parquet(parquet_path, engine="pyarrow")
    times.append(time.perf_counter() - t0)
t_read_p = sorted(times)[len(times) // 2]
print(f"  Read x{runs}:           {ms(t_read_p)} median")
os.unlink(parquet_path)

# ── 4. Parquet uncompressed ────────────────────────────────────────────
print("\n── Parquet (uncompressed) ──")

t0 = time.perf_counter()
df_orig.to_parquet(parquet_path, engine="pyarrow", compression=None)
t_write_pu = time.perf_counter() - t0

pu_size = os.path.getsize(parquet_path)
print(f"  Write:             {ms(t_write_pu)}")
print(f"  Disk:              {size_fmt(pu_size)}  ({pu_size / len(df_orig):.1f} B/row)")

times = []
for _ in range(runs):
    t0 = time.perf_counter()
    df = pd.read_parquet(parquet_path, engine="pyarrow")
    times.append(time.perf_counter() - t0)
t_read_pu = sorted(times)[len(times) // 2]
print(f"  Read x{runs}:           {ms(t_read_pu)} median")
os.unlink(parquet_path)

# ── Summary ─────────────────────────────────────────────────────────────
print(f"\n{'=' * 62}")
print(f"  Format           Disk       Write       Read(median)")
print(f"  {'─' * 52}")
print(f"  pyzdbc            {size_fmt(zdbc_disk):>6}    {ms(t_write_zdbc)}   {ms(t_read_cols)}")
print(f"  Feather          {size_fmt(f_size):>6}    {ms(t_write_f)}   {ms(t_read_f)}")
print(f"  Parquet(snap)    {size_fmt(p_size):>6}    {ms(t_write_p)}   {ms(t_read_p)}")
print(f"  Parquet(none)    {size_fmt(pu_size):>6}    {ms(t_write_pu)}   {ms(t_read_pu)}")
print(f"{'=' * 62}")

# ── Cleanup ─────────────────────────────────────────────────────────────
import shutil
shutil.rmtree(DB_PATH + "dir", ignore_errors=True)
try:
    os.unlink(DB_PATH)
except OSError:
    pass
