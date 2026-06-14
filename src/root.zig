const std = @import("std");
const ColTable = @import("ColTable.zig");
const ColumnIO = @import("ColumnIO.zig");

pub const Table = ColTable.ColTable;
pub const ColType = ColTable.ColType;
pub const ColumnData = ColTable.ColumnData;
pub const ColumnSchema = ColTable.ColumnSchema;
pub const TableSchema = ColTable.TableSchema;
pub const STR8_LEN = ColTable.STR8_LEN;

pub fn ZDBC() type {
    return struct {
        path: []const u8,
        allocator: std.mem.Allocator,
        schemas: std.StringHashMap(TableSchema),
        metadata_buffer: ?[]u8 = null,

        pub fn init(name_file: []const u8, allocator: std.mem.Allocator) !@This() {
            var db = @This(){
                .path = name_file,
                .allocator = allocator,
                .schemas = std.StringHashMap(TableSchema).init(allocator),
            };
            db.loadRegistry() catch |err| {
                if (err != error.FileNotFound) return err;
            };
            return db;
        }

        pub fn deinit(db: *@This()) void {
            var it = db.schemas.iterator();
            while (it.next()) |e| {
                var schema = e.value_ptr;
                schema.deinit(db.allocator);
                db.allocator.free(e.key_ptr.*);
            }
            db.schemas.deinit();
            if (db.metadata_buffer) |b| db.allocator.free(b);
        }

        pub fn ensureDataDir(db: *const @This()) !void {
            const dirname = try std.mem.concat(db.allocator, u8, &.{ db.path, "dir/" });
            defer db.allocator.free(dirname);
            _ = std.fs.cwd().makeOpenPath(dirname, .{}) catch |err| {
                std.log.err("Failed to create data dir: {s}", .{@errorName(err)});
                return err;
            };
        }

        pub fn openDataDir(db: *const @This()) !std.fs.Dir {
            const dirname = try std.mem.concat(db.allocator, u8, &.{ db.path, "dir/" });
            defer db.allocator.free(dirname);
            return std.fs.cwd().openDir(dirname, .{});
        }

        pub fn createTable(db: *@This(), name: []const u8, columns: []const ColumnSchema) !void {
        if (db.schemas.getEntry(name)) |kv| {
            kv.value_ptr.deinit(db.allocator);
            const old_key = kv.key_ptr.*;
            _ = db.schemas.remove(name);
            db.allocator.free(old_key);
        }

        const key_name = try db.allocator.dupe(u8, name);

        var owned_columns = try db.allocator.alloc(ColumnSchema, columns.len);
        errdefer db.allocator.free(owned_columns);
        for (columns, 0..) |col, i| {
            owned_columns[i] = .{
                .name = try db.allocator.dupe(u8, col.name),
                .col_type = col.col_type,
            };
        }

        const schema = TableSchema{
            .name = try db.allocator.dupe(u8, name),
            .columns = owned_columns,
            .num_rows = 0,
        };

        try db.schemas.put(key_name, schema);
        try db.syncRegistry();
    }

        pub fn dropTable(db: *@This(), name: []const u8) !void {
            const kv = db.schemas.getEntry(name) orelse return error.TableNotFound;

            try db.ensureDataDir();
            var dir = try db.openDataDir();
            defer dir.close();

            ColumnIO.deleteColTable(db.allocator, dir, name, kv.value_ptr) catch |err| {
                if (err != error.FileNotFound) return err;
            };

            kv.value_ptr.deinit(db.allocator);
            const key_slice = kv.key_ptr.*;
            _ = db.schemas.remove(name);
            db.allocator.free(key_slice);
            try db.syncRegistry();
        }

        pub fn getTable(db: *const @This(), name: []const u8) ?TableSchema {
            if (db.schemas.get(name)) |schema| {
                return schema;
            }
            return null;
        }

        pub fn hasTable(db: *const @This(), name: []const u8) bool {
            return db.schemas.contains(name);
        }

        pub fn listTables(db: *const @This()) ![][]const u8 {
            var names = std.ArrayList([]const u8){};
            defer names.deinit(db.allocator);
            var it = db.schemas.iterator();
            while (it.next()) |e| {
                try names.append(db.allocator, e.key_ptr.*);
            }
            return names.toOwnedSlice(db.allocator);
        }

        pub fn loadColTable(db: *const @This(), name: []const u8) !ColTable.ColTable {
            try db.ensureDataDir();
            var dir = try db.openDataDir();
            defer dir.close();
            return ColumnIO.loadColTable(db.allocator, dir, name);
        }

        pub fn saveColTable(db: *@This(), name: []const u8, table: *const ColTable.ColTable) !void {
            try db.ensureDataDir();
            var dir = try db.openDataDir();
            defer dir.close();

            try ColumnIO.saveColTable(db.allocator, dir, name, table);

            if (db.schemas.getEntry(name)) |kv| {
                kv.value_ptr.deinit(db.allocator);
                const old_key = kv.key_ptr.*;
                _ = db.schemas.remove(name);
                db.allocator.free(old_key);
            }
            const key_name = try db.allocator.dupe(u8, name);
            var columns = try db.allocator.alloc(ColumnSchema, table.schema.columns.len);
            for (table.schema.columns, 0..) |col, i| {
                columns[i] = .{
                    .name = try db.allocator.dupe(u8, col.name),
                    .col_type = col.col_type,
                };
            }
            const schema_copy = TableSchema{
                .name = try db.allocator.dupe(u8, name),
                .columns = columns,
                .num_rows = table.schema.num_rows,
            };
            try db.schemas.put(key_name, schema_copy);
            try db.syncRegistry();
        }

        pub fn saveTableSchema(db: *@This(), name: []const u8, columns: []const ColumnSchema, num_rows: u64) !void {
            try db.ensureDataDir();
            var dir = try db.openDataDir();
            defer dir.close();

            const schema = TableSchema{
                .name = name,
                .columns = @constCast(columns),
                .num_rows = num_rows,
            };
            try ColumnIO.writeSchema(db.allocator, dir, name, &schema);

            if (db.schemas.getEntry(name)) |kv| {
                kv.value_ptr.deinit(db.allocator);
                const old_key = kv.key_ptr.*;
                _ = db.schemas.remove(name);
                db.allocator.free(old_key);
            }
            const key_name = try db.allocator.dupe(u8, name);
            var owned_columns = try db.allocator.alloc(ColumnSchema, columns.len);
            for (columns, 0..) |col, i| {
                owned_columns[i] = .{
                    .name = try db.allocator.dupe(u8, col.name),
                    .col_type = col.col_type,
                };
            }
            const schema_copy = TableSchema{
                .name = try db.allocator.dupe(u8, name),
                .columns = owned_columns,
                .num_rows = num_rows,
            };
            try db.schemas.put(key_name, schema_copy);
            try db.syncRegistry();
        }

        pub fn readColumn(db: *const @This(), table_name: []const u8, col_name: []const u8) !ColumnData {
            const schema = db.schemas.get(table_name) orelse return error.TableNotFound;
            const col_type = schema.columnType(col_name) orelse return error.ColumnNotFound;

            try db.ensureDataDir();
            var dir = try db.openDataDir();
            defer dir.close();

            return ColumnIO.readColumnFile(db.allocator, dir, table_name, col_name, col_type, schema.num_rows);
        }

        pub fn readColumns(db: *const @This(), table_name: []const u8, col_names: []const []const u8) ![]ColumnData {
            const schema = db.schemas.get(table_name) orelse return error.TableNotFound;
            try db.ensureDataDir();
            var dir = try db.openDataDir();
            defer dir.close();

            const result = try db.allocator.alloc(ColumnData, col_names.len);
            errdefer {
                for (result) |*cd| cd.deinit(db.allocator);
                db.allocator.free(result);
            }

            for (col_names, 0..) |col_name, i| {
                const col_type = schema.columnType(col_name) orelse return error.ColumnNotFound;
                result[i] = ColumnIO.readColumnFile(db.allocator, dir, table_name, col_name, col_type, schema.num_rows) catch |err| {
                    for (result[0..i]) |*cd| cd.deinit(db.allocator);
                    db.allocator.free(result);
                    return err;
                };
            }
            return result;
        }

        pub fn getSchema(db: *const @This(), table_name: []const u8) !TableSchema {
            const existing = db.schemas.get(table_name) orelse return error.TableNotFound;
            var columns = try db.allocator.alloc(ColumnSchema, existing.columns.len);
            errdefer db.allocator.free(columns);
            for (existing.columns, 0..) |col, i| {
                columns[i] = .{
                    .name = try db.allocator.dupe(u8, col.name),
                    .col_type = col.col_type,
                };
            }
            return TableSchema{
                .name = try db.allocator.dupe(u8, table_name),
                .columns = columns,
                .num_rows = existing.num_rows,
            };
        }

        pub fn syncRegistry(db: *const @This()) !void {
            const ftmpname = try std.mem.concat(db.allocator, u8, &.{ db.path, ".tmp" });
            defer db.allocator.free(ftmpname);
            var file = try std.fs.cwd().createFile(ftmpname, .{});
            defer file.close();
            const buff = try db.allocator.alloc(u8, 4096);
            defer db.allocator.free(buff);
            var writer = file.writer(buff);
            var w = &writer.interface;
            try w.writeInt(u32, @intCast(db.schemas.count()), .little);
            var it = db.schemas.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                try w.writeInt(u32, @intCast(k.len), .little);
                try w.writeAll(k);
            }
            try w.flush();
            try std.fs.cwd().rename(ftmpname, db.path);
        }

        fn loadRegistry(db: *@This()) !void {
            var file = std.fs.cwd().openFile(db.path, .{}) catch |err| {
                if (err == error.FileNotFound) return;
                return err;
            };
            defer file.close();
            const stat = try file.stat();
            const size = stat.size;
            const buff = try db.allocator.alloc(u8, @intCast(size));
            db.metadata_buffer = buff;
            var reader = file.reader(buff);
            var r = &reader.interface;
            const table_count = try r.takeInt(u32, .little);
            for (0..table_count) |_| {
                const kl = try r.takeInt(u32, .little);
                const k = try r.take(@intCast(kl));
                const name = try db.allocator.dupe(u8, k);
                errdefer db.allocator.free(name);

                try db.ensureDataDir();
                var dir = try db.openDataDir();
                defer dir.close();

                const schema = ColumnIO.readSchema(db.allocator, dir, name) catch |err| {
                    db.allocator.free(name);
                    if (err == error.TableNotFound) continue;
                    return err;
                };
                try db.schemas.put(name, schema);
            }
        }

        pub fn save(db: *const @This()) !void {
            _ = db;
        }
    };
}

test "Init DB" {
    const alloc = std.heap.page_allocator;
    var db = try ZDBC().init("DB_test", alloc);
    defer db.deinit();
}

test "Create Table with columns" {
    const alloc = std.testing.allocator;
    var db = try ZDBC().init("DB_test", alloc);
    defer db.deinit();

    var columns = [_]ColumnSchema{
        .{ .name = "id", .col_type = .I64 },
        .{ .name = "name", .col_type = .STR8 },
        .{ .name = "score", .col_type = .F64 },
    };
    try db.createTable("players", &columns);
}

test "Drop Table" {
    const alloc = std.testing.allocator;
    var db = try ZDBC().init("DB_test", alloc);
    defer db.deinit();

    var columns = [_]ColumnSchema{
        .{ .name = "id", .col_type = .I64 },
        .{ .name = "name", .col_type = .STR8 },
    };
    try db.createTable("players", &columns);
    try db.dropTable("players");
}

test "Save/Load table roundtrip" {
    const alloc = std.testing.allocator;
    var db = try ZDBC().init("DB_col_roundtrip", alloc);
    defer db.deinit();

    var columns = [_]ColumnSchema{
        .{ .name = "id", .col_type = .I64 },
        .{ .name = "name", .col_type = .STR8 },
        .{ .name = "score", .col_type = .F64 },
    };
    try db.createTable("players", &columns);

    const schema = TableSchema{
        .name = try alloc.dupe(u8, "players"),
        .columns = try alloc.alloc(ColumnSchema, 3),
        .num_rows = 3,
    };
    schema.columns[0] = .{ .name = try alloc.dupe(u8, "id"), .col_type = .I64 };
    schema.columns[1] = .{ .name = try alloc.dupe(u8, "name"), .col_type = .STR8 };
    schema.columns[2] = .{ .name = try alloc.dupe(u8, "score"), .col_type = .F64 };

    var table = try ColTable.ColTable.init(schema, alloc);
    defer table.deinit();

    try table.setI64("id", 0, 1);
    try table.setStr8("name", 0, "Alice");
    try table.setF64("score", 0, 10.0);
    try table.setI64("id", 1, 2);
    try table.setStr8("name", 1, "Bob");
    try table.setF64("score", 1, 20.0);
    try table.setI64("id", 2, 3);
    try table.setStr8("name", 2, "CARL");
    try table.setF64("score", 2, 30.0);

    try db.saveColTable("players", &table);

    var loaded = try db.loadColTable("players");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u64, 3), loaded.rowCount());
    const name0 = try loaded.getStr8("name", 0);
    try std.testing.expectEqualStrings("Alice", name0);
    try std.testing.expectEqual(@as(f64, 20.0), loaded.columns[2].F64[1]);
}

test "Read single column from disk" {
    const alloc = std.testing.allocator;
    var db = try ZDBC().init("DB_readcol", alloc);
    defer db.deinit();

    var columns = [_]ColumnSchema{
        .{ .name = "id", .col_type = .I64 },
        .{ .name = "name", .col_type = .STR8 },
    };
    try db.createTable("items", &columns);

    const schema = TableSchema{
        .name = try alloc.dupe(u8, "items"),
        .columns = try alloc.alloc(ColumnSchema, 2),
        .num_rows = 2,
    };
    schema.columns[0] = .{ .name = try alloc.dupe(u8, "id"), .col_type = .I64 };
    schema.columns[1] = .{ .name = try alloc.dupe(u8, "name"), .col_type = .STR8 };

    var table = try ColTable.ColTable.init(schema, alloc);
    defer table.deinit();

    try table.setI64("id", 0, 42);
    try table.setI64("id", 1, 99);
    try table.setStr8("name", 0, "Foo");
    try table.setStr8("name", 1, "Bar");

    try db.saveColTable("items", &table);

    var name_col = try db.readColumn("items", "name");
    defer name_col.deinit(alloc);

    try std.testing.expect(name_col == .STR8);
    try std.testing.expectEqual(@as(usize, 2), name_col.len());

    const trimmed = std.mem.trimRight(u8, &name_col.STR8[0], " ");
    try std.testing.expectEqualStrings("Foo", trimmed);

    var id_col = try db.readColumn("items", "id");
    defer id_col.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 42), id_col.I64[0]);
    try std.testing.expectEqual(@as(i64, 99), id_col.I64[1]);
}

test "List Tables" {
    const alloc = std.testing.allocator;
    var db = try ZDBC().init("DB_list", alloc);
    defer db.deinit();

    var columns = [_]ColumnSchema{
        .{ .name = "id", .col_type = .I64 },
    };
    try db.createTable("t1", &columns);
    try db.createTable("t2", &columns);

    const names = try db.listTables();
    defer db.allocator.free(names);

    try std.testing.expect(names.len >= 2);
}
