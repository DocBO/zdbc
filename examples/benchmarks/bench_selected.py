#!/usr/bin/env python3
"""Benchmark selected-column batch reads against repeated single-column reads."""

import argparse
import os
import shutil
import sys
import tempfile
import time
import tracemalloc

import numpy as np
import pandas as pd


PROJECT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
os.environ.setdefault("ZDBC_LIB", os.path.join(PROJECT_ROOT, "zig-out", "lib", "libzdbc.so"))
sys.path.insert(0, PROJECT_ROOT)

from pyzdbc import DB, _core
from pyzdbc.db import _parse_batch_result


ROW_COUNTS = (10_000, 100_000, 1_000_000)
COLUMN_COUNTS = (1, 2, 5, 8, 20)


def median_ms(operation, runs):
    times = []
    for _ in range(runs):
        start = time.perf_counter_ns()
        operation()
        times.append((time.perf_counter_ns() - start) / 1_000_000)
    return float(np.median(times))


def peak_python_bytes(operation):
    tracemalloc.start()
    operation()
    _, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    return peak


def read_selected_candidate(db, table_name, selected):
    data, size = _core.read_columns(db._ptr, table_name, selected)
    try:
        return _parse_batch_result(data, size, selected)
    finally:
        _core.free_table(db._ptr, data, size)


def benchmark_case(num_rows, runs):
    db_path = os.path.join(tempfile.gettempdir(), f"zdbc_selected_{num_rows}")
    shutil.rmtree(db_path + "dir", ignore_errors=True)
    try:
        os.unlink(db_path)
    except FileNotFoundError:
        pass

    names = [f"c{i}" for i in range(max(COLUMN_COUNTS))]
    frame = pd.DataFrame({name: np.arange(num_rows, dtype=np.int64) for name in names})

    with DB(db_path) as db:
        db.create_table("wide", {name: "i64" for name in names})
        db.write_table("wide", frame)

        for count in COLUMN_COUNTS:
            selected = names[:count]
            batch = lambda: read_selected_candidate(db, "wide", selected)
            repeated = lambda: db.read_columns("wide", selected)

            start = time.perf_counter_ns()
            batch()
            first_ms = (time.perf_counter_ns() - start) / 1_000_000
            batch_ms = median_ms(batch, runs)
            repeated_ms = median_ms(repeated, runs)
            peak = peak_python_bytes(batch)
            improvement = (repeated_ms - batch_ms) / repeated_ms * 100 if repeated_ms else 0.0

            print(
                f"{num_rows:>9} rows  {count:>2} cols  "
                f"first={first_ms:>8.3f} ms  batch={batch_ms:>8.3f} ms  "
                f"repeated={repeated_ms:>8.3f} ms  delta={improvement:>6.1f}%  "
                f"python_peak={peak / 1024:>9.1f} KiB"
            )

    shutil.rmtree(db_path + "dir", ignore_errors=True)
    try:
        os.unlink(db_path)
    except FileNotFoundError:
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", type=int, nargs="+", default=ROW_COUNTS)
    parser.add_argument("--runs", type=int, default=9)
    args = parser.parse_args()

    print("Selected-column batch benchmark (warm medians; first read reported separately)")
    for num_rows in args.rows:
        benchmark_case(num_rows, args.runs)


if __name__ == "__main__":
    main()