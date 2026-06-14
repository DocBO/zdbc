const std = @import("std");

pub const STR8_LEN: usize = 8;

pub const ColType = enum(u8) {
    I64 = 0,
    F64 = 1,
    STR8 = 2,

    pub fn sizeOf(self: ColType) usize {
        return switch (self) {
            .I64 => @sizeOf(i64),
            .F64 => @sizeOf(f64),
            .STR8 => STR8_LEN,
        };
    }
};

pub const ColumnSchema = struct {
    name: []const u8,
    col_type: ColType,

    pub fn deinit(self: *ColumnSchema, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const TableSchema = struct {
    name: []const u8,
    columns: []ColumnSchema,
    num_rows: u64,

    pub fn deinit(self: *TableSchema, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.columns) |*col| {
            col.deinit(allocator);
        }
        allocator.free(self.columns);
    }

    pub fn columnIndex(self: *const TableSchema, col_name: []const u8) ?usize {
        for (self.columns, 0..) |col, i| {
            if (std.mem.eql(u8, col.name, col_name)) return i;
        }
        return null;
    }

    pub fn columnType(self: *const TableSchema, col_name: []const u8) ?ColType {
        const idx = self.columnIndex(col_name) orelse return null;
        return self.columns[idx].col_type;
    }
};

pub const ColumnData = union(ColType) {
    I64: []i64,
    F64: []f64,
    STR8: [][STR8_LEN]u8,

    pub fn deinit(self: *ColumnData, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .I64 => |slice| allocator.free(slice),
            .F64 => |slice| allocator.free(slice),
            .STR8 => |slice| allocator.free(slice),
        }
    }

    pub fn len(self: ColumnData) usize {
        return switch (self) {
            .I64 => |s| s.len,
            .F64 => |s| s.len,
            .STR8 => |s| s.len,
        };
    }

    pub fn ptr(self: ColumnData) ?*const anyopaque {
        return switch (self) {
            .I64 => |s| @ptrCast(s.ptr),
            .F64 => |s| @ptrCast(s.ptr),
            .STR8 => |s| @ptrCast(s.ptr),
        };
    }

    pub fn byteSize(self: ColumnData, ct: ColType) usize {
        return self.len() * ct.sizeOf();
    }
};

pub const ColTable = struct {
    schema: TableSchema,
    columns: []ColumnData,
    allocator: std.mem.Allocator,

    pub fn init(schema: TableSchema, allocator: std.mem.Allocator) !ColTable {
        const columns = try allocator.alloc(ColumnData, schema.columns.len);
        errdefer allocator.free(columns);

        var col_count: usize = 0;
        errdefer {
            for (columns[0..col_count]) |*col| {
                col.deinit(allocator);
            }
        }

        for (schema.columns, 0..) |col_schema, i| {
            columns[i] = switch (col_schema.col_type) {
                .I64 => .{ .I64 = try allocator.alloc(i64, schema.num_rows) },
                .F64 => .{ .F64 = try allocator.alloc(f64, schema.num_rows) },
                .STR8 => .{ .STR8 = try allocator.alloc([STR8_LEN]u8, schema.num_rows) },
            };
            col_count += 1;
        }

        return ColTable{
            .schema = schema,
            .columns = columns,
            .allocator = allocator,
        };
    }

    /// Creates a ColTable without allocating column data buffers.
    /// Each column is initialized to an empty slice of the correct type.
    /// Used when columns will be filled by reading from files.
    pub fn initLazy(schema: TableSchema, allocator: std.mem.Allocator) !ColTable {
        const columns = try allocator.alloc(ColumnData, schema.columns.len);
        errdefer allocator.free(columns);

        for (schema.columns, 0..) |col_schema, i| {
            columns[i] = switch (col_schema.col_type) {
                .I64 => .{ .I64 = &.{} },
                .F64 => .{ .F64 = &.{} },
                .STR8 => .{ .STR8 = &.{} },
            };
        }

        return ColTable{
            .schema = schema,
            .columns = columns,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ColTable) void {
        for (self.columns) |*col| {
            col.deinit(self.allocator);
        }
        self.allocator.free(self.columns);
        self.schema.deinit(self.allocator);
    }

    pub fn column(self: *const ColTable, col_name: []const u8) ?ColumnData {
        const idx = self.schema.columnIndex(col_name) orelse return null;
        return self.columns[idx];
    }

    pub fn columnIndex(self: *const ColTable, idx: usize) ?ColumnData {
        if (idx >= self.columns.len) return null;
        return self.columns[idx];
    }

    pub fn setI64(self: *ColTable, col_name: []const u8, row: usize, value: i64) !void {
        const idx = self.schema.columnIndex(col_name) orelse return error.ColumnNotFound;
        if (self.columns[idx] != .I64) return error.TypeMismatch;
        self.columns[idx].I64[row] = value;
    }

    pub fn setF64(self: *ColTable, col_name: []const u8, row: usize, value: f64) !void {
        const idx = self.schema.columnIndex(col_name) orelse return error.ColumnNotFound;
        if (self.columns[idx] != .F64) return error.TypeMismatch;
        self.columns[idx].F64[row] = value;
    }

    pub fn setStr8(self: *ColTable, col_name: []const u8, row: usize, value: []const u8) !void {
        const idx = self.schema.columnIndex(col_name) orelse return error.ColumnNotFound;
        if (self.columns[idx] != .STR8) return error.TypeMismatch;
        var buf: [STR8_LEN]u8 = [_]u8{' '} ** STR8_LEN;
        const copy_len = @min(value.len, STR8_LEN);
        @memcpy(buf[0..copy_len], value[0..copy_len]);
        self.columns[idx].STR8[row] = buf;
    }

    pub fn getStr8(self: *const ColTable, col_name: []const u8, row: usize) ![]const u8 {
        const idx = self.schema.columnIndex(col_name) orelse return error.ColumnNotFound;
        if (self.columns[idx] != .STR8) return error.TypeMismatch;
        return std.mem.trimEnd(u8, &self.columns[idx].STR8[row], " ");
    }

    pub fn rowCount(self: *const ColTable) u64 {
        return self.schema.num_rows;
    }

    pub fn colCount(self: *const ColTable) usize {
        return self.schema.columns.len;
    }
};

test "ColTable create and set values" {
    const allocator = std.testing.allocator;

    var columns = try allocator.alloc(ColumnSchema, 3);
    columns[0] = .{ .name = try allocator.dupe(u8, "id"), .col_type = .I64 };
    columns[1] = .{ .name = try allocator.dupe(u8, "name"), .col_type = .STR8 };
    columns[2] = .{ .name = try allocator.dupe(u8, "score"), .col_type = .F64 };

    const schema = TableSchema{
        .name = try allocator.dupe(u8, "players"),
        .columns = columns,
        .num_rows = 2,
    };

    var table = try ColTable.init(schema, allocator);
    defer table.deinit();

    try table.setI64("id", 0, 1);
    try table.setI64("id", 1, 2);
    try table.setStr8("name", 0, "Jon");
    try table.setStr8("name", 1, "Len");
    try table.setF64("score", 0, 100.5);
    try table.setF64("score", 1, 99.0);

    try std.testing.expectEqual(@as(u64, 2), table.rowCount());
    try std.testing.expectEqual(@as(usize, 3), table.colCount());
    try std.testing.expectEqual(@as(i64, 1), table.columns[0].I64[0]);
    try std.testing.expectEqual(@as(i64, 2), table.columns[0].I64[1]);

    const name0 = try table.getStr8("name", 0);
    try std.testing.expectEqualStrings("Jon", name0);
    const name1 = try table.getStr8("name", 1);
    try std.testing.expectEqualStrings("Len", name1);
}

test "Str8 padding and trimming" {
    const allocator = std.testing.allocator;

    var columns = try allocator.alloc(ColumnSchema, 1);
    columns[0] = .{ .name = try allocator.dupe(u8, "code"), .col_type = .STR8 };

    const schema = TableSchema{
        .name = try allocator.dupe(u8, "test"),
        .columns = columns,
        .num_rows = 2,
    };

    var table = try ColTable.init(schema, allocator);
    defer table.deinit();

    try table.setStr8("code", 0, "AB");
    try table.setStr8("code", 1, "LONGNAME");

    const s0 = try table.getStr8("code", 0);
    try std.testing.expectEqualStrings("AB", s0);

    const s1 = try table.getStr8("code", 1);
    try std.testing.expectEqualStrings("LONGNAME", s1);
}
