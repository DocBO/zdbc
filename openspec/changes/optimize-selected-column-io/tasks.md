# Tasks: Optimize Selected-Column I/O

## 1. Baseline and Documentation

- [x] Add benchmark cases for 1, 2, 5, 8, and 20 selected columns at 10,000, 100,000, and 1,000,000 rows.
- [x] Record warm-cache medians separately from first-read observations.
- [x] Capture allocation counts or peak temporary bytes for Python selected reads.
- [x] Reconcile the completed parallel I/O status in `docs/OPTIMIZATION.md`.

## 2. Selected Batch ABI

- [x] Add an additive selected-column batch C ABI function using the existing batch metadata layout.
- [x] Validate requested names and calculate checked buffer sizes before allocation.
- [x] Read selected columns directly into final contiguous-buffer offsets with one data-directory open.
- [x] Reuse the existing STR8 normalization behavior for batch results.
- [x] Ensure all error paths release the batch allocation exactly once.

## 3. Python Integration

- [x] Bind the selected batch symbol in `pyzdbc/_core.py`.
- [x] Evaluate routing `DB.read_columns(..., col_names=...)` through the selected batch operation; retain the existing path because the candidate missed its gate.
- [x] Preserve dictionary keys, NumPy dtypes, independent array ownership, and existing exceptions.

## 4. Adaptive Parallel Reads

- [x] Add direct-to-slice read jobs for non-overlapping batch-buffer regions.
- [x] Benchmark sequential and parallel execution across request sizes and column counts.
- [x] Reject default parallel execution after it regressed measured latency.
- [x] Keep sequential execution because the performance gate was not met.

## 5. Verification

- [ ] Verify selected reads for I64, F64, and STR8 columns and nested table names (runtime pending).
- [ ] Verify missing columns, empty selections, duplicate names, truncated files, and allocation failures (runtime pending).
- [ ] Verify arrays remain valid after the batch buffer and database are freed (runtime pending).
- [x] Compare benchmark results with every performance gate in the proposal; default enablement rejected.

## 6. mmap Feasibility Gate

- [ ] Prototype explicit mapped-buffer ownership for a large single column without changing the default API.
- [ ] Measure Zig-only and end-to-end Python latency, including any required copy.
- [ ] Document lifetime and unmap semantics.
- [ ] Proceed with a separate public mmap change only if the 15% gate is met and ownership is safe.
