const std = @import("std");
const ColTable = @import("ColTable.zig");
const Io = std.Io;

pub const ColType = ColTable.ColType;
pub const ColumnSchema = ColTable.ColumnSchema;
pub const TableSchema = ColTable.TableSchema;
pub const ColumnData = ColTable.ColumnData;
pub const STR8_LEN = ColTable.STR8_LEN;

fn writeIntLe(buf: []u8, comptime T: type, pos: *usize, value: T) void {
    std.mem.writeInt(T, buf[pos.*..][0..@sizeOf(T)], value, .little);
    pos.* += @sizeOf(T);
}

fn readIntLe(buf: []const u8, comptime T: type, pos: *usize) T {
    const value = std.mem.readInt(T, buf[pos.*..][0..@sizeOf(T)], .little);
    pos.* += @sizeOf(T);
    return value;
}

pub fn writeSchema(io: Io, allocator: std.mem.Allocator, dir: Io.Dir, table_name: []const u8, schema: *const TableSchema) !void {
    _ = allocator;
    var schema_name_buf: [256]u8 = undefined;
    const schema_name = try std.fmt.bufPrint(&schema_name_buf, "{s}.schema", .{table_name});

    var file = try dir.createFile(io, schema_name, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    writeIntLe(&buf, u64, &pos, schema.num_rows);
    writeIntLe(&buf, u32, &pos, @intCast(schema.columns.len));

    for (schema.columns) |col| {
        writeIntLe(&buf, u32, &pos, @intCast(col.name.len));
        @memcpy(buf[pos..][0..col.name.len], col.name);
        pos += col.name.len;
        buf[pos] = @intFromEnum(col.col_type);
        pos += 1;
    }
    try file.writeStreamingAll(io, buf[0..pos]);
}

pub fn readSchema(io: Io, allocator: std.mem.Allocator, dir: Io.Dir, table_name: []const u8) !TableSchema {
    var schema_name_buf: [256]u8 = undefined;
    const schema_name = try std.fmt.bufPrint(&schema_name_buf, "{s}.schema", .{table_name});

    var file = dir.openFile(io, schema_name, .{}) catch |err| {
        if (err == error.FileNotFound) return error.TableNotFound;
        return err;
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const buff = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(buff);

    _ = try file.readPositionalAll(io, buff, 0);

    var pos: usize = 0;
    const num_rows = readIntLe(buff, u64, &pos);
    const num_cols = readIntLe(buff, u32, &pos);

    const columns = try allocator.alloc(ColumnSchema, num_cols);
    errdefer {
        for (columns) |*c| c.deinit(allocator);
        allocator.free(columns);
    }

    for (0..num_cols) |i| {
        const name_len = readIntLe(buff, u32, &pos);
        const name_bytes = buff[pos..][0..name_len];
        pos += name_len;
        const type_byte = buff[pos];
        pos += 1;

        const ct: ColType = @enumFromInt(type_byte);
        columns[i] = .{
            .name = try allocator.dupe(u8, name_bytes),
            .col_type = ct,
        };
    }

    const tname = try allocator.dupe(u8, table_name);

    return TableSchema{
        .name = tname,
        .columns = columns,
        .num_rows = num_rows,
    };
}

pub fn readColumnFile(io: Io, allocator: std.mem.Allocator, dir: Io.Dir, table_name: []const u8, col_name: []const u8, col_type: ColType, num_rows: u64) !ColumnData {
    var file_name_buf: [256]u8 = undefined;
    const file_name = try std.fmt.bufPrint(&file_name_buf, "{s}.{s}", .{table_name, col_name});

    var file = dir.openFile(io, file_name, .{}) catch |err| {
        if (err == error.FileNotFound) return error.ColumnNotFound;
        return err;
    };
    defer file.close(io);

    const expected_size = num_rows * col_type.sizeOf();

    return switch (col_type) {
        .I64 => {
            const slice = try allocator.alloc(i64, num_rows);
            errdefer allocator.free(slice);
            const bytes_read = try file.readPositionalAll(io, std.mem.sliceAsBytes(slice), 0);
            if (bytes_read != expected_size) return error.InvalidFormat;
            return .{ .I64 = slice };
        },
        .F64 => {
            const slice = try allocator.alloc(f64, num_rows);
            errdefer allocator.free(slice);
            const bytes_read = try file.readPositionalAll(io, std.mem.sliceAsBytes(slice), 0);
            if (bytes_read != expected_size) return error.InvalidFormat;
            return .{ .F64 = slice };
        },
        .STR8 => {
            const total_bytes = num_rows * STR8_LEN;
            const raw = try allocator.alloc(u8, total_bytes);
            errdefer allocator.free(raw);
            const bytes_read = try file.readPositionalAll(io, raw, 0);
            if (bytes_read != expected_size) return error.InvalidFormat;
            const aligned: [*]align(@alignOf([STR8_LEN]u8)) [STR8_LEN]u8 = @ptrCast(@alignCast(raw.ptr));
            const slice: [][STR8_LEN]u8 = aligned[0..num_rows];
            return .{ .STR8 = slice };
        },
    };
}

/// Like readColumnFile but reads into a pre-allocated buffer instead of allocating new memory.
/// The buffer must be exactly `num_rows * col_type.sizeOf()` bytes.
pub fn readColumnFileIntoBuf(io: Io, allocator: std.mem.Allocator, dir: Io.Dir, table_name: []const u8, col_name: []const u8, col_type: ColType, num_rows: u64, out_buf: []u8) !void {
    _ = allocator;
    var file_name_buf: [256]u8 = undefined;
    const file_name = try std.fmt.bufPrint(&file_name_buf, "{s}.{s}", .{table_name, col_name});

    var file = dir.openFile(io, file_name, .{}) catch |err| {
        if (err == error.FileNotFound) return error.ColumnNotFound;
        return err;
    };
    defer file.close(io);

    const expected_size = num_rows * col_type.sizeOf();
    if (out_buf.len != expected_size) return error.InvalidFormat;
    const bytes_read = try file.readPositionalAll(io, out_buf, 0);
    if (bytes_read != expected_size) return error.InvalidFormat;
}

pub fn writeColumnFile(io: Io, allocator: std.mem.Allocator, dir: Io.Dir, table_name: []const u8, col_name: []const u8, data: ColumnData) !void {
    _ = allocator;
    var file_name_buf: [256]u8 = undefined;
    const file_name = try std.fmt.bufPrint(&file_name_buf, "{s}.{s}", .{table_name, col_name});

    var file = try dir.createFile(io, file_name, .{});
    defer file.close(io);

    switch (data) {
        .I64 => |slice| {
            try file.writeStreamingAll(io, std.mem.sliceAsBytes(slice));
        },
        .F64 => |slice| {
            try file.writeStreamingAll(io, std.mem.sliceAsBytes(slice));
        },
        .STR8 => |slice| {
            try file.writeStreamingAll(io, std.mem.sliceAsBytes(slice));
        },
    }
}

pub fn loadColTable(io: Io, allocator: std.mem.Allocator, dir: Io.Dir, table_name: []const u8) !ColTable.ColTable {
    const schema = try readSchema(io, allocator, dir, table_name);

    var table = try ColTable.ColTable.initLazy(schema, allocator);
    errdefer table.deinit();

    for (0..table.schema.columns.len) |i| {
        const col_schema = table.schema.columns[i];
        table.columns[i] = readColumnFile(io, allocator, dir, table_name, col_schema.name, col_schema.col_type, table.schema.num_rows) catch |err| {
            if (err == error.ColumnNotFound) {
                std.log.warn("Column file missing for {s}.{s}, skipping", .{ table_name, col_schema.name });
                continue;
            }
            return err;
        };
    }

    return table;
}

const ColumnReadJob = struct {
    result: ColumnData,
    err: ?anyerror,
    name: []const u8,
    col_type: ColType,
};

fn columnReadFn(job: *ColumnReadJob, io: Io, allocator: std.mem.Allocator, dir: Io.Dir, table_name: []const u8, num_rows: u64) void {
    job.result = readColumnFile(io, allocator, dir, table_name, job.name, job.col_type, num_rows) catch |err| {
        job.err = err;
        return;
    };
}

/// Reads all columns in parallel using one thread per column.
/// Automatically falls back to sequential reads when per-column data is small
/// enough that thread spawn overhead would dominate (~100 KB threshold).
pub fn readColumnFilesParallel(io: Io, allocator: std.mem.Allocator, dir: Io.Dir, table_name: []const u8, columns: []const ColumnSchema, num_rows: u64, out_results: *[]ColumnData) !void {
    const n = columns.len;
    if (n == 0) return;
    if (n == 1) {
        out_results.*[0].deinit(allocator);
        out_results.*[0] = try readColumnFile(io, allocator, dir, table_name, columns[0].name, columns[0].col_type, num_rows);
        return;
    }

    // All column types are 8 bytes wide → per-column size = num_rows × 8.
    // Thread spawn + join costs ~40 µs; single-column I/O is ~20 µs for 80 KB.
    // Threshold: ~100 KB per column (~12,500 rows) where I/O time ≈ thread overhead.
    const per_col_bytes = @as(usize, @intCast(num_rows)) * 8;
    if (per_col_bytes < 100_000) {
        for (0..n) |i| {
            out_results.*[i].deinit(allocator);
            out_results.*[i] = try readColumnFile(io, allocator, dir, table_name, columns[i].name, columns[i].col_type, num_rows);
        }
        return;
    }

    var jobs = try allocator.alloc(ColumnReadJob, n);
    defer allocator.free(jobs);
    var threads = try allocator.alloc(std.Thread, n);
    defer allocator.free(threads);

    for (0..n) |i| {
        jobs[i] = .{ .result = undefined, .err = null, .name = columns[i].name, .col_type = columns[i].col_type };
    }
    for (0..n) |i| {
        threads[i] = try std.Thread.spawn(.{}, columnReadFn, .{ &jobs[i], io, allocator, dir, table_name, num_rows });
    }

    var first_err: ?anyerror = null;
    for (0..n) |i| {
        threads[i].join();
        if (jobs[i].err) |err| {
            if (first_err == null) first_err = err;
        } else {
            out_results.*[i].deinit(allocator);
            out_results.*[i] = jobs[i].result;
        }
    }
    if (first_err) |err| return err;
}

/// Like loadColTable but reads all column files in parallel.
/// Useful for large tables where per-file I/O dominates thread overhead.
pub fn loadColTableParallel(io: Io, allocator: std.mem.Allocator, dir: Io.Dir, table_name: []const u8) !ColTable.ColTable {
    const schema = try readSchema(io, allocator, dir, table_name);
    var table = try ColTable.ColTable.initLazy(schema, allocator);
    errdefer table.deinit();
    try readColumnFilesParallel(io, allocator, dir, table_name, table.schema.columns, table.schema.num_rows, &table.columns);
    return table;
}

pub fn saveColTable(io: Io, allocator: std.mem.Allocator, dir: Io.Dir, table_name: []const u8, table: *const ColTable.ColTable) !void {
    try writeSchema(io, allocator, dir, table_name, &table.schema);

    for (table.schema.columns, 0..) |col_schema, i| {
        try writeColumnFile(io, allocator, dir, table_name, col_schema.name, table.columns[i]);
    }
}

const ColumnWriteJob = struct {
    err: ?anyerror = null,
    data_ptr: [*]const u8 = undefined,
    data_len: usize = 0,
    name: []const u8 = "",
};

fn columnWriteFn(job: *ColumnWriteJob, io: Io, dir: Io.Dir, table_name: []const u8) void {
    var file_name_buf: [256]u8 = undefined;
    const file_name = std.fmt.bufPrint(&file_name_buf, "{s}.{s}", .{table_name, job.name}) catch {
        job.err = error.NameTooLong;
        return;
    };
    var file = dir.createFile(io, file_name, .{}) catch |err| {
        job.err = err;
        return;
    };
    defer file.close(io);
    file.writeStreamingAll(io, job.data_ptr[0..job.data_len]) catch |err| {
        job.err = err;
    };
}

/// Writes all column files in parallel using one thread per column.
/// Uses the same auto-detection heuristic as the read path (~100 KB per column threshold).
pub fn writeColumnFilesParallel(io: Io, allocator: std.mem.Allocator, dir: Io.Dir, table_name: []const u8, columns: []const ColumnSchema, data: []const ColumnData) !void {
    const n = columns.len;
    if (n == 0) return;
    if (n == 1) return writeColumnFile(io, allocator, dir, table_name, columns[0].name, data[0]);

    const per_col_bytes = data[0].len() * 8;
    if (per_col_bytes < 100_000) {
        for (0..n) |i| {
            try writeColumnFile(io, allocator, dir, table_name, columns[i].name, data[i]);
        }
        return;
    }

    var jobs = try allocator.alloc(ColumnWriteJob, n);
    defer allocator.free(jobs);
    var threads = try allocator.alloc(std.Thread, n);
    defer allocator.free(threads);

    for (0..n) |i| {
        jobs[i] = .{
            .data_ptr = @as([*]const u8, @ptrCast(data[i].ptr().?)),
            .data_len = data[i].len() * columns[i].col_type.sizeOf(),
            .name = columns[i].name,
        };
    }
    for (0..n) |i| {
        threads[i] = try std.Thread.spawn(.{}, columnWriteFn, .{ &jobs[i], io, dir, table_name });
    }
    var first_err: ?anyerror = null;
    for (0..n) |i| {
        threads[i].join();
        if (jobs[i].err) |err| {
            if (first_err == null) first_err = err;
        }
    }
    if (first_err) |err| return err;
}

/// Like saveColTable but writes all column files in parallel.
pub fn saveColTableParallel(io: Io, allocator: std.mem.Allocator, dir: Io.Dir, table_name: []const u8, table: *const ColTable.ColTable) !void {
    try writeSchema(io, allocator, dir, table_name, &table.schema);
    try writeColumnFilesParallel(io, allocator, dir, table_name, table.schema.columns, table.columns);
}

pub fn writeRawColumns(io: Io, allocator: std.mem.Allocator, dir: Io.Dir, table_name: []const u8, columns: []const ColumnSchema, num_rows: u64, data_ptrs: []const [*]const u8, data_lens: []const usize) !void {
    const schema = TableSchema{
        .name = table_name,
        .columns = columns,
        .num_rows = num_rows,
    };
    try writeSchema(io, allocator, dir, table_name, &schema);

    for (columns, 0..) |col, i| {
        var file_name_buf: [256]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&file_name_buf, "{s}.{s}", .{table_name, col.name});

        var file = try dir.createFile(io, file_name, .{});
        defer file.close(io);

        try file.writeStreamingAll(io, data_ptrs[i][0..data_lens[i]]);
    }
}

pub fn deleteColTable(io: Io, allocator: std.mem.Allocator, dir: Io.Dir, table_name: []const u8, schema: *const TableSchema) !void {
    _ = allocator;
    var schema_name_buf: [256]u8 = undefined;
    const schema_name = try std.fmt.bufPrint(&schema_name_buf, "{s}.schema", .{table_name});
    dir.deleteFile(io, schema_name) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    for (schema.columns) |col| {
        var col_file_buf: [256]u8 = undefined;
        const col_file = try std.fmt.bufPrint(&col_file_buf, "{s}.{s}", .{table_name, col.name});
        dir.deleteFile(io, col_file) catch |err| {
            if (err != error.FileNotFound) return err;
        };
    }
}

test "write and read schema" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var columns = try allocator.alloc(ColumnSchema, 2);
    columns[0] = .{ .name = try allocator.dupe(u8, "id"), .col_type = .I64 };
    columns[1] = .{ .name = try allocator.dupe(u8, "name"), .col_type = .STR8 };

    const schema = TableSchema{
        .name = try allocator.dupe(u8, "test"),
        .columns = columns,
        .num_rows = 42,
    };
    var mut_schema_test = schema;
    defer mut_schema_test.deinit(allocator);

    try writeSchema(std.testing.io, allocator, tmp.dir, "test", &schema);

    var loaded = try readSchema(std.testing.io, allocator, tmp.dir, "test");
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 42), loaded.num_rows);
    try std.testing.expectEqual(@as(u32, 2), @as(u32, @intCast(loaded.columns.len)));
    try std.testing.expectEqualStrings("id", loaded.columns[0].name);
    try std.testing.expectEqual(ColType.I64, loaded.columns[0].col_type);
    try std.testing.expectEqualStrings("name", loaded.columns[1].name);
    try std.testing.expectEqual(ColType.STR8, loaded.columns[1].col_type);
}

test "column file roundtrip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const i64_data = try allocator.alloc(i64, 3);
    defer allocator.free(i64_data);
    i64_data[0] = 10;
    i64_data[1] = 20;
    i64_data[2] = 30;

    try writeColumnFile(std.testing.io, allocator, tmp.dir, "test", "id", .{ .I64 = i64_data });

    var loaded = try readColumnFile(std.testing.io, allocator, tmp.dir, "test", "id", .I64, 3);
    defer loaded.deinit(allocator);

    try std.testing.expectEqualSlices(i64, i64_data, loaded.I64);
}

test "full table save/load roundtrip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var columns = try allocator.alloc(ColumnSchema, 3);
    columns[0] = .{ .name = try allocator.dupe(u8, "id"), .col_type = .I64 };
    columns[1] = .{ .name = try allocator.dupe(u8, "name"), .col_type = .STR8 };
    columns[2] = .{ .name = try allocator.dupe(u8, "score"), .col_type = .F64 };

    const schema = TableSchema{
        .name = try allocator.dupe(u8, "players"),
        .columns = columns,
        .num_rows = 3,
    };

    var table = try ColTable.ColTable.init(schema, allocator);
    defer table.deinit();

    try table.setI64("id", 0, 1);
    try table.setI64("id", 1, 2);
    try table.setI64("id", 2, 3);
    try table.setStr8("name", 0, "Alice");
    try table.setStr8("name", 1, "Bob");
    try table.setStr8("name", 2, "Charlie");
    try table.setF64("score", 0, 10.5);
    try table.setF64("score", 1, 20.5);
    try table.setF64("score", 2, 30.5);

    try saveColTable(std.testing.io, allocator, tmp.dir, "players", &table);

    var loaded = try loadColTable(std.testing.io, allocator, tmp.dir, "players");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u64, 3), loaded.rowCount());
    try std.testing.expectEqual(@as(usize, 3), loaded.colCount());
    try std.testing.expectEqual(@as(i64, 1), loaded.columns[0].I64[0]);
    try std.testing.expectEqual(@as(i64, 2), loaded.columns[0].I64[1]);
    try std.testing.expectEqual(@as(i64, 3), loaded.columns[0].I64[2]);

    const name0 = try loaded.getStr8("name", 0);
    try std.testing.expectEqualStrings("Alice", name0);
    const name1 = try loaded.getStr8("name", 1);
    try std.testing.expectEqualStrings("Bob", name1);

    try std.testing.expectEqual(@as(f64, 10.5), loaded.columns[2].F64[0]);
    try std.testing.expectEqual(@as(f64, 20.5), loaded.columns[2].F64[1]);
    try std.testing.expectEqual(@as(f64, 30.5), loaded.columns[2].F64[2]);
}

test "readColumnFileIntoBuf correct and wrong buffer size" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const i64_data = try allocator.alloc(i64, 3);
    defer allocator.free(i64_data);
    i64_data[0] = 100;
    i64_data[1] = 200;
    i64_data[2] = 300;

    try writeColumnFile(std.testing.io, allocator, tmp.dir, "test", "id", .{ .I64 = i64_data });

    var out_buf: [24]u8 align(@alignOf(i64)) = undefined;
    try readColumnFileIntoBuf(std.testing.io, allocator, tmp.dir, "test", "id", .I64, 3, &out_buf);
    const loaded = std.mem.bytesAsSlice(i64, &out_buf);
    try std.testing.expectEqualSlices(i64, i64_data, loaded);

    var bad_buf: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidFormat, readColumnFileIntoBuf(std.testing.io, allocator, tmp.dir, "test", "id", .I64, 3, &bad_buf));
}

test "readColumnFileIntoBuf for all types" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const schema = makeTestSchema(allocator, "alltypes", 1);
    // schema is consumed by ColTable.init below — table.deinit frees it

    var table = try ColTable.ColTable.init(schema, allocator);
    defer table.deinit();
    try table.setI64("id", 0, 42);
    try table.setStr8("name", 0, "TEST");
    try table.setF64("score", 0, 99.5);

    try saveColTable(std.testing.io, allocator, tmp.dir, "alltypes", &table);

    // Read each type via readColumnFileIntoBuf
    var i64_buf: [8]u8 align(@alignOf(i64)) = undefined;
    try readColumnFileIntoBuf(std.testing.io, allocator, tmp.dir, "alltypes", "id", .I64, 1, &i64_buf);
    try std.testing.expectEqual(@as(i64, 42), @as(*const i64, @ptrCast(@alignCast(&i64_buf))).*);

    var f64_buf: [8]u8 align(@alignOf(f64)) = undefined;
    try readColumnFileIntoBuf(std.testing.io, allocator, tmp.dir, "alltypes", "score", .F64, 1, &f64_buf);
    try std.testing.expectEqual(@as(f64, 99.5), @as(*const f64, @ptrCast(@alignCast(&f64_buf))).*);

    var str8_buf: [8]u8 = undefined;
    try readColumnFileIntoBuf(std.testing.io, allocator, tmp.dir, "alltypes", "name", .STR8, 1, &str8_buf);
    try std.testing.expectEqualStrings("TEST", std.mem.trimEnd(u8, &str8_buf, " "));
}

test "loadColTable / loadColTableParallel round-trip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const schema = makeTestSchema(allocator, "roundtrip", 2);

    var table = try ColTable.ColTable.init(schema, allocator);
    defer table.deinit();
    try table.setI64("id", 0, 1);
    try table.setI64("id", 1, 2);
    try table.setStr8("name", 0, "Alice");
    try table.setStr8("name", 1, "Bob");
    try table.setF64("score", 0, 10.0);
    try table.setF64("score", 1, 20.0);

    try saveColTable(std.testing.io, allocator, tmp.dir, "roundtrip", &table);

    // Test that loadColTableParallel produces same result as loadColTable
    var loaded_seq = try loadColTable(std.testing.io, allocator, tmp.dir, "roundtrip");
    defer loaded_seq.deinit();
    var loaded_par = try loadColTableParallel(std.testing.io, allocator, tmp.dir, "roundtrip");
    defer loaded_par.deinit();

    try std.testing.expectEqual(@as(u64, 2), loaded_par.rowCount());
    try std.testing.expectEqual(loaded_seq.columns[0].I64[0], loaded_par.columns[0].I64[0]);
    try std.testing.expectEqual(loaded_seq.columns[0].I64[1], loaded_par.columns[0].I64[1]);
    try std.testing.expectEqual(loaded_seq.columns[1].STR8[0], loaded_par.columns[1].STR8[0]);
    try std.testing.expectEqual(loaded_seq.columns[2].F64[0], loaded_par.columns[2].F64[0]);
}

test "saveColTable / saveColTableParallel round-trip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const schema = makeTestSchema(allocator, "savepar", 1);

    var table = try ColTable.ColTable.init(schema, allocator);
    defer table.deinit();
    try table.setI64("id", 0, 999);
    try table.setStr8("name", 0, "Parallel");
    try table.setF64("score", 0, 42.42);

    // Save with parallel, load with sequential (and vice-versa)
    try saveColTableParallel(std.testing.io, allocator, tmp.dir, "savepar", &table);
    var loaded = try loadColTable(std.testing.io, allocator, tmp.dir, "savepar");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(i64, 999), loaded.columns[0].I64[0]);
    try std.testing.expectEqualStrings("Parallel", try loaded.getStr8("name", 0));
    try std.testing.expectEqual(@as(f64, 42.42), loaded.columns[2].F64[0]);
}

test "readColumnFilesParallel with 0 and 1 columns" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 0 columns — should succeed, no-op
    var empty_results: [0]ColumnData = undefined;
    var empty_slice: []ColumnData = &empty_results;
    try readColumnFilesParallel(std.testing.io, allocator, tmp.dir, "test", &.{}, 0, &empty_slice);

    // 1 column — falls through to simple path
    const schema = makeTestSchema(allocator, "onecol", 1);
    var table = try ColTable.ColTable.init(schema, allocator);
    defer table.deinit();
    try table.setI64("id", 0, 123);
    try saveColTable(std.testing.io, allocator, tmp.dir, "onecol", &table);

    // Create a fresh schema for loading (original schema was consumed by init above)
    const load_schema = makeTestSchema(allocator, "onecol", 1);
    var loaded = try ColTable.ColTable.initLazy(load_schema, allocator);
    defer loaded.deinit();
    try readColumnFilesParallel(std.testing.io, allocator, tmp.dir, "onecol", loaded.schema.columns, 1, &loaded.columns);
    try std.testing.expectEqual(@as(i64, 123), loaded.columns[0].I64[0]);
}

test "writeColumnFilesParallel (sequential fallback for small data)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const schema = makeTestSchema(allocator, "writefallback", 1);

    var table = try ColTable.ColTable.init(schema, allocator);
    defer table.deinit();
    try table.setI64("id", 0, 7);
    try table.setStr8("name", 0, "Fallback");
    try table.setF64("score", 0, 1.23);

    // writeColumnFilesParallel writes column data but not schema — write schema first
    try writeSchema(std.testing.io, allocator, tmp.dir, "writefallback", &table.schema);
    try writeColumnFilesParallel(std.testing.io, allocator, tmp.dir, "writefallback", table.schema.columns, table.columns);

    var loaded = try loadColTable(std.testing.io, allocator, tmp.dir, "writefallback");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(i64, 7), loaded.columns[0].I64[0]);
    try std.testing.expectEqualStrings("Fallback", try loaded.getStr8("name", 0));
    try std.testing.expectEqual(@as(f64, 1.23), loaded.columns[2].F64[0]);
}

test "readSchema TableNotFound" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(error.TableNotFound, readSchema(std.testing.io, allocator, tmp.dir, "nonexistent"));
}

test "readColumnFile ColumnNotFound" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(error.ColumnNotFound, readColumnFile(std.testing.io, allocator, tmp.dir, "test", "nope", .I64, 10));
}

test "table with 0 rows saves and loads" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var columns = try allocator.alloc(ColumnSchema, 1);
    columns[0] = .{ .name = try allocator.dupe(u8, "empty"), .col_type = .I64 };

    const schema = TableSchema{
        .name = try allocator.dupe(u8, "empty_table"),
        .columns = columns,
        .num_rows = 0,
    };

    var table = try ColTable.ColTable.init(schema, allocator);
    defer table.deinit();

    try saveColTable(std.testing.io, allocator, tmp.dir, "empty_table", &table);
    var loaded = try loadColTable(std.testing.io, allocator, tmp.dir, "empty_table");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u64, 0), loaded.rowCount());
    try std.testing.expectEqual(@as(usize, 0), loaded.columns[0].I64.len);
}

fn makeTestSchema(allocator: std.mem.Allocator, name: []const u8, num_rows: u64) TableSchema {
    var columns = allocator.alloc(ColumnSchema, 3) catch unreachable;
    columns[0] = .{ .name = allocator.dupe(u8, "id") catch unreachable, .col_type = .I64 };
    columns[1] = .{ .name = allocator.dupe(u8, "name") catch unreachable, .col_type = .STR8 };
    columns[2] = .{ .name = allocator.dupe(u8, "score") catch unreachable, .col_type = .F64 };

    return TableSchema{
        .name = allocator.dupe(u8, name) catch unreachable,
        .columns = columns,
        .num_rows = num_rows,
    };
}
