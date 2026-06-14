#!/usr/bin/env python3
"""Benchmark pyzdbc module: 10k rows, 5 columns (int, str, float, int, str)."""
import sys, os, time, subprocess

def ms(elapsed_sec: float) -> str:
    return f"{elapsed_sec*1000:8.3f} ms"

def size_fmt(b: int) -> str:
    return f"{b} B" if b < 1024 else f"{b/1024:.1f} KB"

# ── Locate libzdbc.so ───────────────────────────────────────────────────
project_root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
lib_path = os.path.join(project_root, "zig-out", "lib", "libzdbc.so")
if not os.path.exists(lib_path):
    print(f"Building libzdbc.so...")
    subprocess.run(["zig", "build", "shared"], cwd=project_root, check=True)

os.environ["ZDBC_LIB"] = lib_path
sys.path.insert(0, project_root)

print("=" * 58)
print("  pyzdbc BENCHMARK — 10,000 rows x 5 columns")
print("=" * 58)

# ── Generate data via Zig perf benchmark ───────────────────────────────
t0 = time.perf_counter()
subprocess.run(["zig", "build", "perf"], cwd=project_root,
               capture_output=True, text=True)
t_gen = time.perf_counter() - t0
print(f"\nGenerate (Zig subprocess):        {ms(t_gen)}")

# ── Imports ────────────────────────────────────────────────────────────
from pyzdbc import DB
DB_PATH = os.path.join(project_root, "BENCH")

# ── Benchmark: DB.init ─────────────────────────────────────────────────
t0 = time.perf_counter()
db = DB(DB_PATH)
t_init = time.perf_counter() - t0
print(f"DB init:                           {ms(t_init)}")

# ── Benchmark: load_table -> DataFrame ─────────────────────────────────
runs = 5
times = []
for _ in range(runs):
    t0 = time.perf_counter()
    df = db.load_table("bench")
    times.append(time.perf_counter() - t0)
t_load = sorted(times)[len(times)//2]
mem = df.memory_usage(deep=True).sum()
print(f"load_table (median of 5):          {ms(t_load)}  "
      f"({len(df)}r x {len(df.columns)}c, {size_fmt(int(mem))} RAM)")

# ── Benchmark: Pandas operations ───────────────────────────────────────
operations = []

t0 = time.perf_counter(); r = df.query("active == 1 and score > 100")
operations.append(("FILTER (active==1, score>100)", time.perf_counter()-t0, len(r)))

t0 = time.perf_counter(); r = df.groupby("category").agg({"score": "mean", "id": "count"})
operations.append(("GROUPBY category (mean+count)", time.perf_counter()-t0, None))

t0 = time.perf_counter(); r = df.sort_values("score", ascending=False)
operations.append(("SORT score desc", time.perf_counter()-t0, None))

t0 = time.perf_counter(); r = df[df["name"].isin(["Alice", "Bob"])]
operations.append(("FILTER name in [Alice,Bob]", time.perf_counter()-t0, len(r)))

t0 = time.perf_counter(); r = df["score"].mean()
operations.append(("MEAN score", time.perf_counter()-t0, None))

t0 = time.perf_counter(); r = df.corr(numeric_only=True)
operations.append(("CORR matrix (numeric cols)", time.perf_counter()-t0, None))

for name, elapsed, extra in operations:
    extra_s = f" ({extra} rows)" if extra else ""
    print(f"  {name:<36} {ms(elapsed)}{extra_s}")

# ── File sizes ─────────────────────────────────────────────────────────
r_size = os.path.getsize(DB_PATH)
m_size = os.path.getsize(os.path.join(project_root, "BENCHdir", "bench.meta"))
d_size = os.path.getsize(os.path.join(project_root, "BENCHdir", "bench.rows"))
print(f"\nDisk:  registry={size_fmt(r_size)}  .meta={size_fmt(m_size)}  "
      f".rows={size_fmt(d_size)} ({d_size/len(df):.1f} B/row)  "
      f"total={size_fmt(r_size+m_size+d_size)}")

# ── Close ──────────────────────────────────────────────────────────────
t0 = time.perf_counter()
db.close()
t_close = time.perf_counter() - t0
print(f"\nDB close:                          {ms(t_close)}")

# ── Summary ────────────────────────────────────────────────────────────
total = t_gen + t_init + t_load + sum(e for _, e, _ in operations) + t_close
print(f"\n{'='*58}")
print(f"  TOTAL measured:                  {ms(total)}")
print(f"  Throughput: 10k rows / 5 cols / {d_size/1024:.0f} KB")
print(f"  Disk density: {d_size/len(df):.1f} B/row (binary, variable-length)")
print(f"{'='*58}")
