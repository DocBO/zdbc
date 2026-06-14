const std = @import("std");
const ColTable = @import("ColTable.zig");
const ColumnIO = @import("ColumnIO.zig");
const Io = std.Io;

pub const Table = ColTable.ColTable;
pub const ColType = ColTable.ColType;
pub const ColumnData = ColTable.ColumnData;
pub const ColumnSchema = ColTable.ColumnSchema;
pub const TableSchema = ColTable.TableSchema;
pub const STR8_LEN = ColTable.STR8_LEN;

var global_io_threaded: Io.Threaded = .init_single_threaded;
pub const global_io: Io = global_io_threaded.io();

pub fn ZDBC() type {
    return struct {
        path: []const u8,
        allocator: std.mem.Allocator,
        schemas: std.StringHashMap(TableSchema),
        metadata_buffer: ?[]u8 = null,
        io: Io,
        data_dir_ensured: bool = false,

        pub fn init(name_file: []const u8, allocator: std.mem.Allocator) !@This() {
            var db = @This(){
                .path = name_file,
                .allocator = allocator,
                .schemas = std.StringHashMap(TableSchema).init(allocator),
                .io = global_io,
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

        pub fn ensureDataDir(db: *@This()) !void {
            if (db.data_dir_ensured) return;
            var dirname_buf: [256]u8 = undefined;
            const dirname = try std.fmt.bufPrint(&dirname_buf, "{s}dir/", .{db.path});
            Io.Dir.cwd().createDirPath(db.io, dirname) catch |err| {
                std.log.err("Failed to create data dir: {s}", .{@errorName(err)});
                return err;
            };
            db.data_dir_ensured = true;
        }

        pub fn openDataDir(db: *const @This()) !Io.Dir {
            var dirname_buf: [256]u8 = undefined;
            const dirname = try std.fmt.bufPrint(&dirname_buf, "{s}dir/", .{db.path});
            return Io.Dir.cwd().openDir(db.io, dirname, .{});
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
            defer dir.close(db.io);

            ColumnIO.deleteColTable(db.io, db.allocator, dir, name, kv.value_ptr) catch |err| {
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
            var names = std.ArrayList([]const u8).empty;
            defer names.deinit(db.allocator);
            var it = db.schemas.iterator();
            while (it.next()) |e| {
                const copy = try db.allocator.dupe(u8, e.key_ptr.*);
                try names.append(db.allocator, copy);
            }
            return names.toOwnedSlice(db.allocator);
        }

        pub fn loadColTable(db: *@This(), name: []const u8) !ColTable.ColTable {
            try db.ensureDataDir();
            var dir = try db.openDataDir();
            defer dir.close(db.io);
            return ColumnIO.loadColTable(db.io, db.allocator, dir, name);
        }

        pub fn saveColTable(db: *@This(), name: []const u8, table: *const ColTable.ColTable) !void {
            try db.ensureDataDir();
            var dir = try db.openDataDir();
            defer dir.close(db.io);

            try ColumnIO.saveColTable(db.io, db.allocator, dir, name, table);

            try db.updateRegistryEntry(name, &table.schema);
        }

        pub fn saveColTableParallel(db: *@This(), name: []const u8, table: *const ColTable.ColTable) !void {
            try db.ensureDataDir();
            var dir = try db.openDataDir();
            defer dir.close(db.io);

            try ColumnIO.saveColTableParallel(db.io, db.allocator, dir, name, table);

            try db.updateRegistryEntry(name, &table.schema);
        }

        fn updateRegistryEntry(db: *@This(), name: []const u8, schema: *const TableSchema) !void {
            if (db.schemas.getEntry(name)) |kv| {
                kv.value_ptr.deinit(db.allocator);
                const old_key = kv.key_ptr.*;
                _ = db.schemas.remove(name);
                db.allocator.free(old_key);
            }
            const key_name = try db.allocator.dupe(u8, name);
            var columns = try db.allocator.alloc(ColumnSchema, schema.columns.len);
            for (schema.columns, 0..) |col, i| {
                columns[i] = .{
                    .name = try db.allocator.dupe(u8, col.name),
                    .col_type = col.col_type,
                };
            }
            const schema_copy = TableSchema{
                .name = try db.allocator.dupe(u8, name),
                .columns = columns,
                .num_rows = schema.num_rows,
            };
            try db.schemas.put(key_name, schema_copy);
            try db.syncRegistry();
        }

        pub fn saveTableSchema(db: *@This(), name: []const u8, columns: []const ColumnSchema, num_rows: u64) !void {
            try db.ensureDataDir();
            var dir = try db.openDataDir();
            defer dir.close(db.io);

            const schema = TableSchema{
                .name = name,
                .columns = @constCast(columns),
                .num_rows = num_rows,
            };
            try ColumnIO.writeSchema(db.io, db.allocator, dir, name, &schema);
            try db.updateRegistryEntry(name, &schema);
        }

        pub fn readColumn(db: *@This(), table_name: []const u8, col_name: []const u8) !ColumnData {
            const schema = db.schemas.get(table_name) orelse return error.TableNotFound;
            const col_type = schema.columnType(col_name) orelse return error.ColumnNotFound;

            try db.ensureDataDir();
            var dir = try db.openDataDir();
            defer dir.close(db.io);

            return ColumnIO.readColumnFile(db.io, db.allocator, dir, table_name, col_name, col_type, schema.num_rows);
        }

        pub fn readColumns(db: *@This(), table_name: []const u8, col_names: []const []const u8) ![]ColumnData {
            const schema = db.schemas.get(table_name) orelse return error.TableNotFound;
            try db.ensureDataDir();
            var dir = try db.openDataDir();
            defer dir.close(db.io);

            const result = try db.allocator.alloc(ColumnData, col_names.len);
            errdefer {
                for (result) |*cd| cd.deinit(db.allocator);
                db.allocator.free(result);
            }

            for (col_names, 0..) |col_name, i| {
                const col_type = schema.columnType(col_name) orelse return error.ColumnNotFound;
                result[i] = ColumnIO.readColumnFile(db.io, db.allocator, dir, table_name, col_name, col_type, schema.num_rows) catch |err| {
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
            var ftmpname_buf: [256]u8 = undefined;
            const ftmpname = try std.fmt.bufPrint(&ftmpname_buf, "{s}.tmp", .{db.path});
            var file = try Io.Dir.cwd().createFile(db.io, ftmpname, .{});
            defer file.close(db.io);

            // Serialize table count + names into a buffer
            var buf: [4096]u8 = undefined;
            var pos: usize = 0;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(db.schemas.count()), .little);
            pos += 4;
            var it = db.schemas.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                std.mem.writeInt(u32, buf[pos..][0..4], @intCast(k.len), .little);
                pos += 4;
                @memcpy(buf[pos..][0..k.len], k);
                pos += k.len;
            }
            try file.writeStreamingAll(db.io, buf[0..pos]);

            const cwd = Io.Dir.cwd();
            try Io.Dir.rename(cwd, ftmpname, cwd, db.path, db.io);
        }

        fn loadRegistry(db: *@This()) !void {
            var file = Io.Dir.cwd().openFile(db.io, db.path, .{}) catch |err| {
                if (err == error.FileNotFound) return;
                return err;
            };
            defer file.close(db.io);
            const stat = try file.stat(db.io);
            const size = stat.size;
            const buff = try db.allocator.alloc(u8, @intCast(size));
            db.metadata_buffer = buff;
            _ = try file.readPositionalAll(db.io, buff, 0);

            var pos: usize = 0;
            const table_count = std.mem.readInt(u32, buff[pos..][0..4], .little);
            pos += 4;
            for (0..table_count) |_| {
                const kl = std.mem.readInt(u32, buff[pos..][0..4], .little);
                pos += 4;
                const k = buff[pos..][0..kl];
                pos += kl;
                const name = try db.allocator.dupe(u8, k);
                errdefer db.allocator.free(name);

                try db.ensureDataDir();
                var dir = try db.openDataDir();
                defer dir.close(db.io);

                const schema = ColumnIO.readSchema(db.io, db.allocator, dir, name) catch |err| {
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

    const trimmed = std.mem.trimEnd(u8, &name_col.STR8[0], " ");
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
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }

    try std.testing.expect(names.len >= 2);
}

test "Multiple tables create, read, drop" {
    const alloc = std.testing.allocator;
    var db = try ZDBC().init("DB_multitable", alloc);
    defer db.deinit();

    var cols = [_]ColumnSchema{.{ .name = "id", .col_type = .I64 }};

    try db.createTable("t1", &cols);
    try db.createTable("t2", &cols);
    try db.createTable("t3", &cols);

    try std.testing.expect(db.hasTable("t1"));
    try std.testing.expect(db.hasTable("t2"));
    try std.testing.expect(db.hasTable("t3"));
    try std.testing.expect(!db.hasTable("t4"));

    try db.dropTable("t2");
    try std.testing.expect(!db.hasTable("t2"));
    try std.testing.expect(db.hasTable("t1"));
    try std.testing.expect(db.hasTable("t3"));
}

test "saveColTableParallel + loadColTable data integrity" {
    const alloc = std.testing.allocator;
    var db = try ZDBC().init("DB_datacheck", alloc);
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
        .num_rows = 100,
    };
    schema.columns[0] = .{ .name = try alloc.dupe(u8, "id"), .col_type = .I64 };
    schema.columns[1] = .{ .name = try alloc.dupe(u8, "name"), .col_type = .STR8 };
    schema.columns[2] = .{ .name = try alloc.dupe(u8, "score"), .col_type = .F64 };

    var table = try ColTable.ColTable.init(schema, alloc);
    defer table.deinit();

    var rng = std.Random.DefaultPrng.init(42);
    const names = [_][]const u8{ "Alice", "Bob", "Carl", "Diana" };
    for (0..100) |i| {
        try table.setI64("id", i, @intCast(i * 2));
        try table.setStr8("name", i, names[rng.random().uintLessThan(usize, names.len)]);
        try table.setF64("score", i, @as(f64, @floatFromInt(rng.random().uintLessThan(u32, 100000))) / 100.0);
    }

    try db.saveColTableParallel("players", &table);
    var loaded = try db.loadColTable("players");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u64, 100), loaded.rowCount());
    for (0..100) |i| {
        try std.testing.expectEqual(@as(i64, @intCast(i * 2)), loaded.columns[0].I64[i]);
        // score should match exactly (no precision loss for integers/100)
        try std.testing.expectEqual(table.columns[2].F64[i], loaded.columns[2].F64[i]);
    }
    // STR8 must round-trip
    for (0..100) |i| {
        try std.testing.expectEqual(table.columns[1].STR8[i], loaded.columns[1].STR8[i]);
    }
}

test "readColumns with specific column subset" {
    const alloc = std.testing.allocator;
    var db = try ZDBC().init("DB_subset", alloc);
    defer db.deinit();

    var columns = [_]ColumnSchema{
        .{ .name = "id", .col_type = .I64 },
        .{ .name = "name", .col_type = .STR8 },
        .{ .name = "score", .col_type = .F64 },
    };
    try db.createTable("items", &columns);

    const schema = TableSchema{
        .name = try alloc.dupe(u8, "items"),
        .columns = try alloc.alloc(ColumnSchema, 3),
        .num_rows = 5,
    };
    schema.columns[0] = .{ .name = try alloc.dupe(u8, "id"), .col_type = .I64 };
    schema.columns[1] = .{ .name = try alloc.dupe(u8, "name"), .col_type = .STR8 };
    schema.columns[2] = .{ .name = try alloc.dupe(u8, "score"), .col_type = .F64 };

    var table = try ColTable.ColTable.init(schema, alloc);
    defer table.deinit();
    for (0..5) |i| {
        try table.setI64("id", i, @intCast(i + 1));
        try table.setStr8("name", i, "Item");
        try table.setF64("score", i, @floatFromInt(i));
    }
    try db.saveColTable("items", &table);

    // Read only id + score (skip name)
    const subset = try db.readColumns("items", &.{ "id", "score" });
    defer {
        for (subset) |*cd| cd.deinit(alloc);
        alloc.free(subset);
    }

    try std.testing.expectEqual(@as(usize, 2), subset.len);
    try std.testing.expectEqual(@as(i64, 1), subset[0].I64[0]);
    try std.testing.expectEqual(@as(i64, 5), subset[0].I64[4]);
    try std.testing.expectEqual(@as(f64, 0.0), subset[1].F64[0]);
    try std.testing.expectEqual(@as(f64, 4.0), subset[1].F64[4]);
}

test "Table with 0 and 1 row" {
    const alloc = std.testing.allocator;
    var db = try ZDBC().init("DB_tiny", alloc);
    defer db.deinit();

    var columns = [_]ColumnSchema{.{ .name = "id", .col_type = .I64 }};
    try db.createTable("zero", &columns);

    // 0 rows
    var schema0 = TableSchema{
        .name = try alloc.dupe(u8, "zero"),
        .columns = try alloc.alloc(ColumnSchema, 1),
        .num_rows = 0,
    };
    schema0.columns[0] = .{ .name = try alloc.dupe(u8, "id"), .col_type = .I64 };
    var table0 = try ColTable.ColTable.init(schema0, alloc);
    defer table0.deinit();
    try db.saveColTable("zero", &table0);
    var loaded0 = try db.loadColTable("zero");
    defer loaded0.deinit();
    try std.testing.expectEqual(@as(u64, 0), loaded0.rowCount());

    // 1 row
    try db.createTable("one", &columns);
    var schema1 = TableSchema{
        .name = try alloc.dupe(u8, "one"),
        .columns = try alloc.alloc(ColumnSchema, 1),
        .num_rows = 1,
    };
    schema1.columns[0] = .{ .name = try alloc.dupe(u8, "id"), .col_type = .I64 };
    var table1 = try ColTable.ColTable.init(schema1, alloc);
    defer table1.deinit();
    try table1.setI64("id", 0, 42);
    try db.saveColTable("one", &table1);
    var loaded1 = try db.loadColTable("one");
    defer loaded1.deinit();
    try std.testing.expectEqual(@as(u64, 1), loaded1.rowCount());
    try std.testing.expectEqual(@as(i64, 42), loaded1.columns[0].I64[0]);
}

test "Table with many columns" {
    const alloc = std.testing.allocator;
    var db = try ZDBC().init("DB_wide", alloc);
    defer db.deinit();

    const ncols = 20;
    var columns = try alloc.alloc(ColumnSchema, ncols);
    defer {
        for (columns) |c| alloc.free(c.name);
        alloc.free(columns);
    }
    for (0..ncols) |i| {
        var name_buf: [8]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "c{d}", .{i});
        columns[i] = .{ .name = try alloc.dupe(u8, name), .col_type = .I64 };
    }

    try db.createTable("wide", columns);

    var schema = TableSchema{
        .name = try alloc.dupe(u8, "wide"),
        .columns = try alloc.alloc(ColumnSchema, ncols),
        .num_rows = 10,
    };
    for (0..ncols) |i| {
        var name_buf: [8]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "c{d}", .{i});
        schema.columns[i] = .{ .name = try alloc.dupe(u8, name), .col_type = .I64 };
    }

    var table = try ColTable.ColTable.init(schema, alloc);
    defer table.deinit();
    for (0..ncols) |c| {
        for (0..10) |r| {
            try table.setI64(table.schema.columns[c].name, r, @intCast(c * 100 + r));
        }
    }

    try db.saveColTable("wide", &table);
    var loaded = try db.loadColTable("wide");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u64, 10), loaded.rowCount());
    try std.testing.expectEqual(@as(usize, ncols), loaded.colCount());
    try std.testing.expectEqual(@as(i64, 507), loaded.columns[5].I64[7]);
    try std.testing.expectEqual(@as(i64, 1900), loaded.columns[19].I64[0]);
}

