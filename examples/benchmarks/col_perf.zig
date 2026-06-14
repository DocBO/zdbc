const std = @import("std");
const zdbc = @import("zdbc");

const ColType = zdbc.ColType;
const ColumnSchema = zdbc.ColumnSchema;
const TableSchema = zdbc.TableSchema;
const STR8_LEN = zdbc.STR8_LEN;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const table_name = "bench";
    const num_rows = 10000;
    const num_cols = 5;

    const names = [_][]const u8{ "Alice", "Bob", "Charlie", "Diana", "Eve", "Frank", "Grace", "Hank" };
    const categories = [_][]const u8{ "A", "B", "C", "D" };
    var rng = std.Random.DefaultPrng.init(42);

    std.debug.print("COLUMN-ORIENTED BENCHMARK — {d} rows x {d} columns\n", .{ num_rows, num_cols });
    std.debug.print("============================================================\n", .{});

    // ── Phase 1: Generate column data in memory ─────────────────────
    var timer = try std.time.Timer.start();
    var start = timer.read();

    const col_defs = [_]ColumnSchema{
        .{ .name = "id", .col_type = .I64 },
        .{ .name = "name", .col_type = .STR8 },
        .{ .name = "score", .col_type = .F64 },
        .{ .name = "active", .col_type = .I64 },
        .{ .name = "category", .col_type = .STR8 },
    };

    var schema = TableSchema{
        .name = try allocator.dupe(u8, table_name),
        .columns = try allocator.alloc(ColumnSchema, num_cols),
        .num_rows = num_rows,
    };
    for (col_defs, 0..) |cd, i| {
        schema.columns[i] = .{
            .name = try allocator.dupe(u8, cd.name),
            .col_type = cd.col_type,
        };
    }

    var table = try zdbc.Table.init(schema, allocator);
    defer table.deinit();

    for (0..num_rows) |i| {
        try table.setI64("id", i, @intCast(i));
        try table.setStr8("name", i, names[rng.random().uintLessThan(usize, names.len)]);
        try table.setF64("score", i, @as(f64, @floatFromInt(rng.random().uintLessThan(u32, 10000))) / 10.0);
        try table.setI64("active", i, @intFromBool(rng.random().boolean()));
        try table.setStr8("category", i, categories[rng.random().uintLessThan(usize, categories.len)]);
    }
    const gen_ns = timer.read() - start;
    std.debug.print("GENERATE  {d:>6} rows: {d:>8.3} ms  ({d:>7.1} ns/row)\n", .{ num_rows, @as(f64, @floatFromInt(gen_ns)) / 1_000_000, @as(f64, @floatFromInt(gen_ns)) / @as(f64, @floatFromInt(num_rows)) });

    // ── Phase 2: Create DB and write to disk ─────────────────────────
    var db = try zdbc.DB().init("COL_BENCH", allocator);
    defer db.deinit();
    try db.createTable(table_name, &col_defs);

    start = timer.read();
    try db.saveColTable(table_name, &table);
    const save_ns = timer.read() - start;
    var data_dir = try std.fs.cwd().openDir("COL_BENCHdir", .{});
    defer data_dir.close();

    std.debug.print("SAVE     {d:>6} rows: {d:>8.3} ms\n", .{ num_rows, @as(f64, @floatFromInt(save_ns)) / 1_000_000 });

    // ── Phase 3: File sizes ──────────────────────────────────────────
    std.debug.print("\nColumn file sizes:\n", .{});
    var total_disk: u64 = 0;
    for (col_defs) |cd| {
        const fname = try std.mem.concat(allocator, u8, &.{ table_name, ".", cd.name });
        defer allocator.free(fname);
        const stat = data_dir.statFile(fname) catch |err| {
            std.debug.print("  {s:>10}: (missing: {s})\n", .{ cd.name, @errorName(err) });
            continue;
        };
        total_disk += stat.size;
        const bprow = @as(f64, @floatFromInt(stat.size)) / @as(f64, @floatFromInt(num_rows));
        std.debug.print("  {s:>10}: {d:>8} B  ({d:.1} B/row)\n", .{ cd.name, stat.size, bprow });
    }
    const reg = try std.fs.cwd().statFile("COL_BENCH");
    const sch = data_dir.statFile("bench.schema") catch std.fs.File.Stat{
        .size = 0,
        .kind = .file,
        .ctime = 0,
        .mtime = 0,
        .atime = 0,
        .inode = 0,
        .mode = 0,
    };
    std.debug.print("  {s:>10}: {d:>8} B\n", .{ "registry", reg.size });
    std.debug.print("  {s:>10}: {d:>8} B\n", .{ "schema", sch.size });
    std.debug.print("  {s:>10}: {d:>8} B  ({d:.1} B/row total)\n", .{ "TOTAL", total_disk + reg.size + sch.size, @as(f64, @floatFromInt(total_disk)) / @as(f64, @floatFromInt(num_rows)) });

    // ── Phase 4: Read single column ──────────────────────────────────
    start = timer.read();
    var id_col = try db.readColumn(table_name, "id");
    defer id_col.deinit(allocator);
    const read1_ns = timer.read() - start;
    std.debug.print("\nREAD 1 col (id):    {d:>8.3} ms\n", .{@as(f64, @floatFromInt(read1_ns)) / 1_000_000});

    // ── Phase 5: Read column pair ────────────────────────────────────
    const pair_names = [_][]const u8{ "name", "score" };
    start = timer.read();
    const pair = try db.readColumns(table_name, &pair_names);
    defer {
        for (pair) |*col| col.deinit(allocator);
        allocator.free(pair);
    }
    const read2_ns = timer.read() - start;
    std.debug.print("READ 2 col (name+score): {d:>8.3} ms\n", .{@as(f64, @floatFromInt(read2_ns)) / 1_000_000});

    // ── Phase 6: Load full table ─────────────────────────────────────
    start = timer.read();
    var loaded = try db.loadColTable(table_name);
    defer loaded.deinit();
    const load_ns = timer.read() - start;
    std.debug.print("LOAD full table:   {d:>8.3} ms\n", .{@as(f64, @floatFromInt(load_ns)) / 1_000_000});

    // ── Phase 7: Iterate and aggregate over column data ──────────────
    start = timer.read();
    var sum_id: i64 = 0;
    var sum_score: f64 = 0;
    var sum_active: i64 = 0;
    const id_data = loaded.columns[0].I64;
    const score_data = loaded.columns[2].F64;
    const active_data = loaded.columns[3].I64;
    for (0..num_rows) |i| {
        sum_id += id_data[i];
        sum_score += score_data[i];
        sum_active += active_data[i];
    }
    const iter_ns = timer.read() - start;
    std.debug.print("AGGREGATE columns: {d:>8.3} ms  (sum_id={d}, sum_score={d:.1}, sum_active={d})\n", .{ @as(f64, @floatFromInt(iter_ns)) / 1_000_000, sum_id, sum_score, sum_active });

    // ── Phase 8: Repeated single column reads (hot cache) ────────────
    start = timer.read();
    const runs = 10;
    for (0..runs) |_| {
        var col = try db.readColumn(table_name, "id");
        col.deinit(allocator);
    }
    const hot_ns = timer.read() - start;
    std.debug.print("\nHOT READ  id x{d}:     {d:>8.3} ms  ({d:.1} us/read)\n", .{ runs, @as(f64, @floatFromInt(hot_ns)) / 1_000_000, @as(f64, @floatFromInt(hot_ns)) / 1_000 / @as(f64, @floatFromInt(runs)) });

    std.debug.print("\n============================================================\n", .{});
}
