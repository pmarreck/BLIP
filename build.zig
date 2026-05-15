const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // ---------------------------------------------------------------------
    // printable-binary (vendored under vendor/printable_binary/)
    // ---------------------------------------------------------------------

    const pb_module = b.createModule(.{
        .root_source_file = b.path("vendor/printable_binary/printable_binary.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---------------------------------------------------------------------
    // Core BLIP module — used by the static lib, tests, and benchmarks
    // ---------------------------------------------------------------------

    const blip_module = b.createModule(.{
        .root_source_file = b.path("src/blip.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "printable_binary", .module = pb_module },
        },
    });

    // Empty build_options so blip.zig's `@import("build_options")` keeps working.
    const build_options = b.addOptions();
    blip_module.addOptions("build_options", build_options);

    // Exposed downstream module: dep.module("blip")
    const exposed_blip = b.addModule("blip", .{
        .root_source_file = b.path("src/blip.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "printable_binary", .module = pb_module },
        },
    });
    exposed_blip.addOptions("build_options", build_options);

    // ---------------------------------------------------------------------
    // Static library — the C FFI surface (libblip.a)
    // ---------------------------------------------------------------------

    const static_lib = b.addLibrary(.{
        .name = "blip",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "blip", .module = blip_module },
                .{ .name = "printable_binary", .module = pb_module },
            },
        }),
    });
    if (b.option(bool, "emit-lib-llvm-ir", "Emit LLVM IR for the static library") orelse false) {
        const ir_install = b.addInstallFile(static_lib.getEmittedLlvmIr(), "blip-lib.ll");
        b.getInstallStep().dependOn(&ir_install.step);
    }
    b.installArtifact(static_lib);

    // ---------------------------------------------------------------------
    // blip-bench: dogfoods the C FFI from a Zig main()
    // ---------------------------------------------------------------------

    const exe = b.addExecutable(.{
        .name = "blip-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.linkLibrary(static_lib);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the FFI smoke-test CLI");
    run_step.dependOn(&run_cmd.step);

    // ---------------------------------------------------------------------
    // blip-benchmark: direct-Zig benchmarks (no FFI)
    // ---------------------------------------------------------------------

    const bench = b.addExecutable(.{
        .name = "blip-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "blip", .module = blip_module },
            },
        }),
    });
    if (b.option(bool, "emit-llvm-ir", "Emit LLVM IR for the benchmark binary") orelse false) {
        const ir_install = b.addInstallFile(bench.getEmittedLlvmIr(), "blip-benchmark.ll");
        b.getInstallStep().dependOn(&ir_install.step);
    }
    b.installArtifact(bench);

    const bench_run = b.addRunArtifact(bench);
    bench_run.step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_run.step);

    // ---------------------------------------------------------------------
    // printable-binary CLI (vendored)
    // ---------------------------------------------------------------------

    const pb_exe = b.addExecutable(.{
        .name = "printable-binary",
        .root_module = b.createModule(.{
            .root_source_file = b.path("vendor/printable_binary/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "printable_binary", .module = pb_module },
            },
        }),
    });
    b.installArtifact(pb_exe);

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    const unit_test_module = b.createModule(.{
        .root_source_file = b.path("src/blip.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "printable_binary", .module = pb_module },
        },
    });
    unit_test_module.addOptions("build_options", build_options);
    const unit_tests = b.addTest(.{ .root_module = unit_test_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const ffi_test_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "blip", .module = blip_module },
            .{ .name = "printable_binary", .module = pb_module },
        },
    });
    ffi_test_module.addOptions("build_options", build_options);
    const ffi_tests = b.addTest(.{ .root_module = ffi_test_module });
    const run_ffi_tests = b.addRunArtifact(ffi_tests);

    const test_step = b.step("test", "Run unit + FFI tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_ffi_tests.step);
}
