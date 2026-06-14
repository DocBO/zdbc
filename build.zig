const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zdbc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const static_lib = b.addLibrary(.{
        .name = "zdbc",
        .linkage = .static,
        .root_module = mod,
    });

    const default_step = b.step("default", "Build library");
    default_step.dependOn(&static_lib.step);

    const shared_lib = b.addLibrary(.{
        .name = "zdbc",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cabi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zdbc", .module = mod },
            },
        }),
    });
    shared_lib.linkLibC();

    const shared_step = b.step("shared", "Build shared library for Python");
    shared_step.dependOn(&shared_lib.step);
    shared_step.dependOn(&b.addInstallArtifact(shared_lib, .{}).step);

    const col_perf = b.addExecutable(.{
        .name = "col_perf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/benchmarks/col_perf.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zdbc", .module = mod },
            },
        }),
    });

    const col_perf_step = b.step("col_perf", "column-oriented performance benchmark");
    const col_perf_cmd = b.addRunArtifact(col_perf);
    col_perf_step.dependOn(&col_perf_cmd.step);
    col_perf_cmd.step.dependOn(b.getInstallStep());

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    b.installArtifact(static_lib);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
