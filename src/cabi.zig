const std = @import("std");
const ZDBC = @import("root.zig").ZDBC();
const ColTable = @import("ColTable.zig");
const ColumnIO = @import("ColumnIO.zig");
const Io = std.Io;

const ColType = ColTable.ColType;
const ColumnSchema = ColTable.ColumnSchema;
const TableSchema = ColTable.TableSchema;
const STR8_LEN = ColTable.STR8_LEN;

fn newArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.heap.c_allocator);
}

fn trimStr8Buffer(data: [*]u8, count: usize) void {
    const rows: [*][STR8_LEN]u8 = @ptrCast(@alignCast(data));
    const space_word: u64 = 0x2020202020202020;
    for (0..count) |i| {
        const s = &rows[i];
        const word: u64 = @bitCast(s.*);
        const xored = word ^ space_word;
        if (xored == 0) {
            s.* = [_]u8{0} ** STR8_LEN;
            continue;
        }
        // @clz gives leading zero bits. Eight per byte, from the MSB (byte 7 in LE).
        const trailing_space_bytes = @clz(xored) / 8;
        const keep_bytes: u6 = @intCast(STR8_LEN - trailing_space_bytes);
        // mask keeps the lower keep_bytes*8 bits, zeros the upper bits
        const mask: u64 = if (keep_bytes == 8) ~@as(u64, 0) else (@as(u64, 1) << @as(u6, @intCast(keep_bytes * 8))) - 1;
        s.* = @bitCast(word & mask);
    }
}

export fn zdbc_init(path: [*:0]const u8) ?*ZDBC {
    const gpa = std.heap.c_allocator;
    const name = std.mem.span(path);
    const duped = gpa.dupe(u8, name) catch return null;
    const db = gpa.create(ZDBC) catch {
        gpa.free(duped);
        return null;
    };
    db.* = ZDBC.init(duped, gpa) catch {
        gpa.free(duped);
        gpa.destroy(db);
        return null;
    };
    return db;
}

export fn zdbc_deinit(db: *ZDBC) void {
    const allocator = db.allocator;
    const path = db.path;
    db.deinit();
    allocator.free(path);
    allocator.destroy(db);
}

export fn zdbc_create_table(db: *ZDBC, name: [*:0]const u8, col_names: [*]const [*:0]const u8, col_types: [*]const u8, num_cols: i32) i32 {
    const name_slice = std.mem.span(name);
    const n = @as(usize, @intCast(num_cols));

    var arena = newArena();
    defer arena.deinit();
    const aa = arena.allocator();

    var columns = aa.alloc(ColumnSchema, n) catch return -6;

    for (0..n) |i| {
        const cn = std.mem.span(col_names[i]);
        columns[i] = .{
            .name = cn,
            .col_type = @enumFromInt(col_types[i]),
        };
    }

    db.createTable(name_slice, columns) catch |err| {
        return mapError(err);
    };
    return 0;
}

export fn zdbc_drop_table(db: *ZDBC, name: [*:0]const u8) i32 {
    db.dropTable(std.mem.span(name)) catch |err| {
        return mapError(err);
    };
    return 0;
}

export fn zdbc_list_tables(db: *ZDBC, out_buf: [*]u8, buf_len: u64) i32 {
    const names = db.listTables() catch return -6;
    defer {
        for (names) |n| db.allocator.free(n);
        db.allocator.free(names);
    }

    var offset: usize = 0;
    for (names) |name| {
        const needed = name.len + 1;
        if (offset + needed > buf_len) return -3;
        @memcpy(out_buf[offset..][0..name.len], name);
        out_buf[offset + name.len] = '\n';
        offset += needed;
    }
    if (offset > 0 and out_buf[offset - 1] == '\n') {
        out_buf[offset - 1] = 0;
    }
    return 0;
}

export fn zdbc_table_row_count(db: *ZDBC, name: [*:0]const u8) i64 {
    const schema = db.schemas.get(std.mem.span(name)) orelse return -1;
    return @intCast(schema.num_rows);
}

export fn zdbc_table_column_count(db: *ZDBC, name: [*:0]const u8) i32 {
    const schema = db.schemas.get(std.mem.span(name)) orelse return -1;
    return @intCast(schema.columns.len);
}

export fn zdbc_table_column_info(db: *ZDBC, name: [*:0]const u8, index: i32, out_name: [*]u8, name_len: u64, out_type: *u8) i32 {
    const schema = db.schemas.get(std.mem.span(name)) orelse return -1;
    if (index < 0 or @as(usize, @intCast(index)) >= schema.columns.len) return -3;

    const col = schema.columns[@intCast(index)];
    const copy_len = @min(col.name.len, @as(usize, @intCast(name_len)) - 1);
    @memcpy(out_name[0..copy_len], col.name[0..copy_len]);
    out_name[copy_len] = 0;
    out_type.* = @intFromEnum(col.col_type);
    return 0;
}

export fn zdbc_read_column(db: *ZDBC, table_name: [*:0]const u8, col_name: [*:0]const u8, out_data: *?*anyopaque, out_count: *i64, out_type: *u8) i32 {
    const col_data = db.readColumn(std.mem.span(table_name), std.mem.span(col_name)) catch |err| {
        return mapError(err);
    };

    const ct: ColType = switch (col_data) {
        .I64 => .I64,
        .F64 => .F64,
        .STR8 => .STR8,
    };

    out_data.* = @constCast(col_data.ptr().?);
    out_count.* = @intCast(col_data.len());
    out_type.* = @intFromEnum(ct);
    // STR8 returned as raw S8 bytes — Python handles null/padding decode natively
    return 0;
}

export fn zdbc_free_column(db: *ZDBC, data: ?*anyopaque) void {
    _ = db;
    if (data) |ptr| {
        const slice: []u8 = @as([*]u8, @ptrCast(ptr))[0..0];
        std.heap.c_allocator.free(slice);
    }
}

export fn zdbc_free_sized_column(db: *ZDBC, data: ?*anyopaque, count: i64, col_type: u8) void {
    if (data) |ptr| {
        const ct: ColType = @enumFromInt(col_type);
        const total = @as(usize, @intCast(count)) * ct.sizeOf();
        db.allocator.free(@as([*]u8, @ptrCast(ptr))[0..total]);
    }
}

const BATCH_COL_NAME_LEN = 32;
const BATCH_COL_META_SIZE = 64;

const BatchColumnMeta = extern struct {
    name: [BATCH_COL_NAME_LEN]u8,
    col_type: u8,
    _pad1: [7]u8 = [_]u8{0} ** 7,
    count: i64,
    byte_len: i64,
    data_offset: i64,
};

const BatchTableHeader = extern struct {
    num_rows: i64,
    num_columns: i32,
    _pad2: [4]u8 = [_]u8{0} ** 4,
};

fn batchTableHeaderSize(num_cols: usize) usize {
    return @sizeOf(BatchTableHeader) + num_cols * BATCH_COL_META_SIZE;
}

fn readBatch(db: *ZDBC, table_name: []const u8, columns: []const ColumnSchema, num_rows: u64, out_data: *?*anyopaque, out_size: *i64) i32 {
    if (num_rows > std.math.maxInt(i64) or columns.len > std.math.maxInt(i32)) return -3;
    const row_count = std.math.cast(usize, num_rows) orelse return -3;
    const header_size = std.math.add(
        usize,
        @sizeOf(BatchTableHeader),
        std.math.mul(usize, columns.len, BATCH_COL_META_SIZE) catch return -3,
    ) catch return -3;

    // Open the data dir once — not per column
    db.ensureDataDir() catch |err| return mapError(err);
    var dir = db.openDataDir() catch |err| return mapError(err);
    defer dir.close(db.io);

    // Phase 1: measure total data size
    var data_total: usize = 0;
    for (columns) |col| {
        const byte_len = std.math.mul(usize, col.col_type.sizeOf(), row_count) catch return -3;
        data_total = std.math.add(usize, data_total, byte_len) catch return -3;
    }

    // Phase 2: allocate the output buffer up front
    const total = std.math.add(usize, header_size, data_total) catch return -3;
    if (total > std.math.maxInt(i64)) return -3;
    const buf = db.allocator.alloc(u8, total) catch return -6;

    var arena = newArena();
    defer arena.deinit();
    const out_buffers = arena.allocator().alloc([]u8, columns.len) catch {
        db.allocator.free(buf);
        return -6;
    };

    // Write header
    {
        const hdr_slice = buf[0..@sizeOf(BatchTableHeader)];
        var hdr: *BatchTableHeader = @ptrCast(@alignCast(hdr_slice.ptr));
        hdr.num_rows = @intCast(num_rows);
        hdr.num_columns = @intCast(columns.len);
    }

    // Phase 3: describe each column and its final output region
    const meta_off = @sizeOf(BatchTableHeader);
    const meta_slice = buf[meta_off..header_size];
    var metas: [*]BatchColumnMeta = @ptrCast(@alignCast(meta_slice.ptr));

    var cur_offs: usize = header_size;
    for (columns, 0..) |col, i| {
        const byte_len = col.col_type.sizeOf() * row_count;

        const col_data_slice = buf[cur_offs..][0..byte_len];
        out_buffers[i] = col_data_slice;

        var meta = &metas[i];
        @memset(meta.name[0..], 0);
        const name_len = @min(col.name.len, BATCH_COL_NAME_LEN - 1);
        @memcpy(meta.name[0..name_len], col.name[0..name_len]);
        meta.col_type = @intFromEnum(col.col_type);
        meta.count = @intCast(num_rows);
        meta.byte_len = @intCast(byte_len);
        meta.data_offset = @intCast(cur_offs);
        cur_offs += byte_len;
    }

    // Phase 4: read directly into final offsets. Benchmarks rejected parallel execution.
    ColumnIO.readColumnFilesIntoBuf(
        db.io, db.allocator, dir, table_name, columns, num_rows, out_buffers,
    ) catch |err| {
        db.allocator.free(buf);
        return mapError(err);
    };

    // Trim STR8 columns in-place
    for (columns, 0..) |col, i| {
        if (col.col_type == .STR8) {
            const meta = &metas[i];
            const off: usize = @intCast(meta.data_offset);
            const cnt: usize = @intCast(meta.count);
            trimStr8Buffer(buf.ptr + off, cnt);
        }
    }

    out_data.* = buf.ptr;
    out_size.* = @intCast(total);
    return 0;
}

export fn zdbc_read_table(db: *ZDBC, table_name: [*:0]const u8, out_data: *?*anyopaque, out_size: *i64) i32 {
    const name_slice = std.mem.span(table_name);
    const schema = db.schemas.get(name_slice) orelse return -1;
    return readBatch(db, name_slice, schema.columns, schema.num_rows, out_data, out_size);
}

export fn zdbc_read_columns(db: *ZDBC, table_name: [*:0]const u8, col_names: [*]const [*:0]const u8, num_cols: i32, out_data: *?*anyopaque, out_size: *i64) i32 {
    if (num_cols < 0) return -3;

    const name_slice = std.mem.span(table_name);
    const schema = db.schemas.get(name_slice) orelse return -1;
    const n: usize = @intCast(num_cols);

    var arena = newArena();
    defer arena.deinit();
    const selected = arena.allocator().alloc(ColumnSchema, n) catch return -6;

    for (0..n) |i| {
        const col_name = std.mem.span(col_names[i]);
        const index = schema.columnIndex(col_name) orelse return -2;
        selected[i] = schema.columns[index];
    }

    return readBatch(db, name_slice, selected, schema.num_rows, out_data, out_size);
}

export fn zdbc_free_table(db: *ZDBC, data: ?*anyopaque, size: i64) void {
    if (data) |ptr| {
        db.allocator.free(@as([*]u8, @ptrCast(ptr))[0..@intCast(size)]);
    }
}

export fn zdbc_write_table(db: *ZDBC, name: [*:0]const u8, col_names: [*]const [*:0]const u8, col_types: [*]const u8, num_cols: i32, column_data: [*]?*anyopaque, num_rows: i64) i32 {
    const name_slice = std.mem.span(name);
    const n = @as(usize, @intCast(num_cols));
    const rows = @as(u64, @intCast(num_rows));

    var arena = newArena();
    defer arena.deinit();
    const aa = arena.allocator();

    var schemas = aa.alloc(ColumnSchema, n) catch return -6;

    for (0..n) |i| {
        const cn = std.mem.span(col_names[i]);
        const ct: ColType = @enumFromInt(col_types[i]);
        schemas[i] = .{
            .name = aa.dupe(u8, cn) catch return -6,
            .col_type = ct,
        };
    }

    // Write column files directly from Python data pointers
    db.ensureDataDir() catch |err| return mapError(err);
    var dir = db.openDataDir() catch |err| return mapError(err);
    defer dir.close(db.io);

    for (0..n) |i| {
        const ptr = column_data[i] orelse return -4;
        const ct: ColType = @enumFromInt(col_types[i]);
        const byte_len = rows * ct.sizeOf();

        const file_name = std.mem.concat(aa, u8, &.{ name_slice, ".", schemas[i].name }) catch return -6;
        ColumnIO.ensureFilePath(db.io, dir, file_name) catch |err| return mapError(err);
        var file = dir.createFile(db.io, file_name, .{}) catch |err| return mapError(err);
        defer file.close(db.io);
        file.writeStreamingAll(db.io, @as([*]const u8, @ptrCast(ptr))[0..byte_len]) catch return -6;
    }

    // Write schema file and update registry
    db.saveTableSchema(name_slice, schemas, rows) catch |err| return mapError(err);

    return 0;
}

fn mapError(err: anyerror) i32 {
    return switch (err) {
        error.TableNotFound => -1,
        error.TableNotLoaded => -2,
        error.SchemaError => -3,
        error.InvalidFormat => -4,
        error.InvalidType => -5,
        error.ColumnNotFound => -7,
        error.FileNotFound => -1,
        else => -99,
    };
}
