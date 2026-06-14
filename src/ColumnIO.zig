const std = @import("std");
const ColTable = @import("ColTable.zig");

pub const ColType = ColTable.ColType;
pub const ColumnSchema = ColTable.ColumnSchema;
pub const TableSchema = ColTable.TableSchema;
pub const ColumnData = ColTable.ColumnData;
pub const STR8_LEN = ColTable.STR8_LEN;

pub fn writeSchema(allocator: std.mem.Allocator, dir: std.fs.Dir, table_name: []const u8, schema: *const TableSchema) !void {
    const schema_name = try std.mem.concat(allocator, u8, &.{ table_name, ".schema" });
    defer allocator.free(schema_name);

    const buff = try allocator.alloc(u8, 4096);
    defer allocator.free(buff);

    var file = try dir.createFile(schema_name, .{});
    defer file.close();

    var writer = file.writer(buff);
    var w = &writer.interface;

    try w.writeInt(u64, schema.num_rows, .little);
    try w.writeInt(u32, @intCast(schema.columns.len), .little);

    for (schema.columns) |col| {
        try w.writeInt(u32, @intCast(col.name.len), .little);
        try w.writeAll(col.name);
        try w.writeByte(@intFromEnum(col.col_type));
    }
    try w.flush();
}

pub fn readSchema(allocator: std.mem.Allocator, dir: std.fs.Dir, table_name: []const u8) !TableSchema {
    const schema_name = try std.mem.concat(allocator, u8, &.{ table_name, ".schema" });
    defer allocator.free(schema_name);

    var file = dir.openFile(schema_name, .{}) catch |err| {
        if (err == error.FileNotFound) return error.TableNotFound;
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    const buff = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(buff);

    var reader = file.reader(buff);
    var r = &reader.interface;

    const num_rows = try r.takeInt(u64, .little);
    const num_cols = try r.takeInt(u32, .little);

    const columns = try allocator.alloc(ColumnSchema, num_cols);
    errdefer {
        for (columns) |*c| c.deinit(allocator);
        allocator.free(columns);
    }

    for (0..num_cols) |i| {
        const name_len = try r.takeInt(u32, .little);
        const name_bytes = try r.take(name_len);
        const type_byte = try r.take(1);

        const ct: ColType = @enumFromInt(type_byte[0]);
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

pub fn readColumnFile(allocator: std.mem.Allocator, dir: std.fs.Dir, table_name: []const u8, col_name: []const u8, col_type: ColType, num_rows: u64) !ColumnData {
    const file_name = try std.mem.concat(allocator, u8, &.{ table_name, ".", col_name });
    defer allocator.free(file_name);

    var file = dir.openFile(file_name, .{}) catch |err| {
        if (err == error.FileNotFound) return error.ColumnNotFound;
        return err;
    };
    defer file.close();

    const expected_size = num_rows * col_type.sizeOf();

    return switch (col_type) {
        .I64 => {
            const slice = try allocator.alloc(i64, num_rows);
            errdefer allocator.free(slice);
            const bytes_read = try file.readAll(std.mem.sliceAsBytes(slice));
            if (bytes_read != expected_size) return error.InvalidFormat;
            return .{ .I64 = slice };
        },
        .F64 => {
            const slice = try allocator.alloc(f64, num_rows);
            errdefer allocator.free(slice);
            const bytes_read = try file.readAll(std.mem.sliceAsBytes(slice));
            if (bytes_read != expected_size) return error.InvalidFormat;
            return .{ .F64 = slice };
        },
        .STR8 => {
            const total_bytes = num_rows * STR8_LEN;
            const raw = try allocator.alloc(u8, total_bytes);
            errdefer allocator.free(raw);
            const bytes_read = try file.readAll(raw);
            if (bytes_read != expected_size) return error.InvalidFormat;
            const aligned: [*]align(@alignOf([STR8_LEN]u8)) [STR8_LEN]u8 = @ptrCast(@alignCast(raw.ptr));
            const slice: [][STR8_LEN]u8 = aligned[0..num_rows];
            return .{ .STR8 = slice };
        },
    };
}

pub fn writeColumnFile(allocator: std.mem.Allocator, dir: std.fs.Dir, table_name: []const u8, col_name: []const u8, data: ColumnData) !void {
    const file_name = try std.mem.concat(allocator, u8, &.{ table_name, ".", col_name });
    defer allocator.free(file_name);

    var file = try dir.createFile(file_name, .{});
    defer file.close();

    switch (data) {
        .I64 => |slice| {
            try file.writeAll(std.mem.sliceAsBytes(slice));
        },
        .F64 => |slice| {
            try file.writeAll(std.mem.sliceAsBytes(slice));
        },
        .STR8 => |slice| {
            try file.writeAll(std.mem.sliceAsBytes(slice));
        },
    }
}

pub fn loadColTable(allocator: std.mem.Allocator, dir: std.fs.Dir, table_name: []const u8) !ColTable.ColTable {
    const schema = try readSchema(allocator, dir, table_name);
    const num_rows = schema.num_rows;
    const num_cols = schema.columns.len;

    var table = try ColTable.ColTable.init(schema, allocator);
    errdefer table.deinit();

    for (0..num_cols) |i| {
        const col_schema = table.schema.columns[i];
        const data = readColumnFile(allocator, dir, table_name, col_schema.name, col_schema.col_type, num_rows) catch |err| {
            if (err == error.ColumnNotFound) {
                std.log.warn("Column file missing for {s}.{s}, skipping", .{ table_name, col_schema.name });
                continue;
            }
            return err;
        };
        table.columns[i].deinit(allocator);
        table.columns[i] = data;
    }

    return table;
}

pub fn saveColTable(allocator: std.mem.Allocator, dir: std.fs.Dir, table_name: []const u8, table: *const ColTable.ColTable) !void {
    try writeSchema(allocator, dir, table_name, &table.schema);

    for (table.schema.columns, 0..) |col_schema, i| {
        try writeColumnFile(allocator, dir, table_name, col_schema.name, table.columns[i]);
    }
}

pub fn writeRawColumns(allocator: std.mem.Allocator, dir: std.fs.Dir, table_name: []const u8, columns: []const ColumnSchema, num_rows: u64, data_ptrs: []const [*]const u8, data_lens: []const usize) !void {
    const schema = TableSchema{
        .name = table_name,
        .columns = columns,
        .num_rows = num_rows,
    };
    try writeSchema(allocator, dir, table_name, &schema);

    for (columns, 0..) |col, i| {
        const file_name = try std.mem.concat(allocator, u8, &.{ table_name, ".", col.name });
        defer allocator.free(file_name);

        var file = try dir.createFile(file_name, .{});
        defer file.close();

        try file.writeAll(data_ptrs[i][0..data_lens[i]]);
    }
}

pub fn deleteColTable(allocator: std.mem.Allocator, dir: std.fs.Dir, table_name: []const u8, schema: *const TableSchema) !void {
    const schema_name = try std.mem.concat(allocator, u8, &.{ table_name, ".schema" });
    defer allocator.free(schema_name);
    dir.deleteFile(schema_name) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    for (schema.columns) |col| {
        const col_file = try std.mem.concat(allocator, u8, &.{ table_name, ".", col.name });
        defer allocator.free(col_file);
        dir.deleteFile(col_file) catch |err| {
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

    try writeSchema(allocator, tmp.dir, "test", &schema);

    var loaded = try readSchema(allocator, tmp.dir, "test");
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

    try writeColumnFile(allocator, tmp.dir, "test", "id", .{ .I64 = i64_data });

    var loaded = try readColumnFile(allocator, tmp.dir, "test", "id", .I64, 3);
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

    try saveColTable(allocator, tmp.dir, "players", &table);

    var loaded = try loadColTable(allocator, tmp.dir, "players");
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
