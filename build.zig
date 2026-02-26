const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode",
    ) orelse .ReleaseFast;

    // printable-binary module (vendored) — needed by static lib for peek FFI
    // NOTE: must be defined before blip_module so it can be imported
    const pb_module = b.createModule(.{
        .root_source_file = b.path("vendor/printable_binary/printable_binary.zig"),
        .target = target,
        .optimize = optimize,
    });

    // z7z dependency — provides LZMA2 compression engine
    const z7z_dep = b.dependency("z7z", .{
        .target = target,
        .optimize = optimize,
    });
    const z7z_module = z7z_dep.module("z7z");

    // Core BLIP module — shared by library, tests, and benchmarks
    const blip_module = b.createModule(.{
        .root_source_file = b.path("src/blip.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "printable_binary", .module = pb_module },
            .{ .name = "z7z", .module = z7z_module },
        },
    });

    // Expose named modules for downstream Zig consumers:
    //   dep.module("blip")      — full API (blip.zig + printable_binary)
    //   dep.module("mini_blar") — archive creation/reading (mini_blar.zig)
    _ = b.addModule("blip", .{
        .root_source_file = b.path("src/blip.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "printable_binary", .module = pb_module },
            .{ .name = "z7z", .module = z7z_module },
        },
    });

    _ = b.addModule("mini_blar", .{
        .root_source_file = b.path("src/mini_blar.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "printable_binary", .module = pb_module },
            .{ .name = "z7z", .module = z7z_module },
        },
    });

    // Static library (C FFI surface)
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
    b.installArtifact(static_lib);

    // CLI executable — calls through C FFI (links static lib)
    const exe = b.addExecutable(.{
        .name = "blip-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibrary(static_lib);
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the benchmark CLI");
    run_step.dependOn(&run_cmd.step);

    // blar CLI executable — C program that links against the static lib
    const blar = b.addExecutable(.{
        .name = "blar",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    blar.addCSourceFile(.{
        .file = b.path("src/blar.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic" },
    });
    blar.linkLibrary(static_lib);
    blar.root_module.addIncludePath(b.path("src"));
    b.installArtifact(blar);

    const blar_run_cmd = b.addRunArtifact(blar);
    blar_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        blar_run_cmd.addArgs(args);
    }
    const blar_run_step = b.step("blar", "Run the blar archive CLI");
    blar_run_step.dependOn(&blar_run_cmd.step);

    // miniblar CLI executable — C program that links against the static lib
    const miniblar = b.addExecutable(.{
        .name = "miniblar",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    miniblar.addCSourceFile(.{
        .file = b.path("src/miniblar.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic" },
    });
    miniblar.linkLibrary(static_lib);
    miniblar.root_module.addIncludePath(b.path("src"));
    b.installArtifact(miniblar);

    const miniblar_run_cmd = b.addRunArtifact(miniblar);
    miniblar_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        miniblar_run_cmd.addArgs(args);
    }
    const miniblar_run_step = b.step("miniblar", "Run the miniblar archive CLI");
    miniblar_run_step.dependOn(&miniblar_run_cmd.step);

    // printable-binary CLI executable (vendored)
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

    // Unit tests (exercises blip.zig directly)
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/blip.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "printable_binary", .module = pb_module },
                .{ .name = "z7z", .module = z7z_module },
            },
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // FFI tests (exercises lib.zig C FFI surface)
    const ffi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "blip", .module = blip_module },
                .{ .name = "printable_binary", .module = pb_module },
                .{ .name = "z7z", .module = z7z_module },
            },
        }),
    });
    const run_ffi_tests = b.addRunArtifact(ffi_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_ffi_tests.step);

    // Benchmark step — direct Zig access to all encodings
    const bench = b.addExecutable(.{
        .name = "blip-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "blip", .module = blip_module },
            },
        }),
    });
    b.installArtifact(bench);

    const bench_run = b.addRunArtifact(bench);
    bench_run.step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_run.step);
}
