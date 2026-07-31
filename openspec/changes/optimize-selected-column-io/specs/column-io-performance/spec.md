# Column I/O Performance Delta

## ADDED Requirements

### Requirement: Selected columns use one batch request

The Python selected-column read path SHALL request all selected columns through one C ABI operation and one contiguous result allocation.

#### Scenario: Read multiple selected columns

- **WHEN** a caller requests two or more existing columns by name
- **THEN** the system reads only those column files
- **AND** performs one selected batch C ABI call
- **AND** returns the same keys and NumPy dtypes as the existing selected-column API

#### Scenario: Requested column is missing

- **WHEN** any requested column does not exist
- **THEN** the operation fails with the existing column-not-found behavior
- **AND** returns no partial result
- **AND** releases all temporary resources

### Requirement: Batch reads write directly to final offsets

The Zig batch path SHALL read each column into its final non-overlapping region of the contiguous output buffer without an intermediate full-column allocation and copy.

#### Scenario: Mixed column types

- **WHEN** selected I64, F64, and STR8 columns are read together
- **THEN** each metadata entry describes the correct type, count, byte length, and data offset
- **AND** every data region lies within the returned allocation
- **AND** STR8 output matches existing batch normalization

### Requirement: Parallelism is adaptive

The batch read path SHALL use sequential I/O for requests below the measured parallel break-even point and MAY use parallel I/O above it.

#### Scenario: Small request

- **WHEN** request size is below the benchmark-selected threshold
- **THEN** columns are read sequentially

#### Scenario: Large eligible request

- **WHEN** at least two columns are requested above the benchmark-selected threshold
- **THEN** the implementation may read files concurrently into disjoint output regions
- **AND** joins all started work before returning or releasing the output buffer

### Requirement: Existing ownership remains stable

Returned Python arrays SHALL own independent memory under the existing `DB.read_column` and `DB.read_columns` APIs.

#### Scenario: Database closes after a read

- **WHEN** a read completes and the database is subsequently closed
- **THEN** previously returned NumPy arrays remain valid and unchanged

### Requirement: Performance changes are benchmark-gated

The implementation SHALL publish before-and-after medians for the benchmark matrix and SHALL retain the existing path when the proposal's regression gates are not met.

#### Scenario: Optimization misses its gate

- **WHEN** a proposed parallel or mapped strategy misses its stated performance gate
- **THEN** that strategy is not enabled in the default read path
