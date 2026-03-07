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

    // bzip2z dependency — provides bzip2 compression engine
    const bzip2z_dep = b.dependency("bzip2z", .{
        .target = target,
        .optimize = optimize,
    });
    const bzip2z_module = bzip2z_dep.module("bzip2z");

    // lz4 dependency — provides LZ4 compression (C library)
    const lz4_dep = b.dependency("lz4", .{
        .target = target,
        .optimize = optimize,
    });
    const lz4_lib = lz4_dep.artifact("lz4");

    // zstdz dependency — provides Zstandard compression (C library)
    const zstdz_dep = b.dependency("zstdz", .{
        .target = target,
        .optimize = optimize,
    });
    const zstdz_lib = zstdz_dep.artifact("zstd");

    // progrez dependency — provides progress bar (C library)
    const progrez_dep = b.dependency("progrez", .{
        .target = target,
        .optimize = optimize,
    });
    const progrez_lib = progrez_dep.artifact("progrez");

    // libjxl system library — provides JPEG XL lossless recompression for PDF container expansion.
    // Paths provided via -D options (set by flake.nix) or discovered via pkg-config.
    const jxl_include_path = b.option([]const u8, "jxl-include-path", "Path to libjxl headers");
    const jxl_lib_path = b.option([]const u8, "jxl-lib-path", "Path to libjxl libraries");

    // Core BLIP module — shared by library, tests, and benchmarks
    const blip_module = b.createModule(.{
        .root_source_file = b.path("src/blip.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "printable_binary", .module = pb_module },
            .{ .name = "z7z", .module = z7z_module },
            .{ .name = "bzip2z", .module = bzip2z_module },
        },
    });
    blip_module.linkLibrary(lz4_lib);
    blip_module.linkLibrary(zstdz_lib);
    // libjxl: add include/lib paths and link
    if (jxl_include_path) |inc| blip_module.addSystemIncludePath(.{ .cwd_relative = inc });
    if (jxl_lib_path) |lib| blip_module.addLibraryPath(.{ .cwd_relative = lib });
    blip_module.linkSystemLibrary("jxl", .{});
    blip_module.linkSystemLibrary("jxl_threads", .{});

    // Expose named modules for downstream Zig consumers:
    //   dep.module("blip")      — full API (blip.zig + printable_binary)
    //   dep.module("mini_blar") — archive creation/reading (mini_blar.zig)
    const exposed_blip = b.addModule("blip", .{
        .root_source_file = b.path("src/blip.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "printable_binary", .module = pb_module },
            .{ .name = "z7z", .module = z7z_module },
            .{ .name = "bzip2z", .module = bzip2z_module },
        },
    });
    exposed_blip.linkLibrary(lz4_lib);
    exposed_blip.linkLibrary(zstdz_lib);
    if (jxl_include_path) |inc| exposed_blip.addSystemIncludePath(.{ .cwd_relative = inc });
    if (jxl_lib_path) |lib| exposed_blip.addLibraryPath(.{ .cwd_relative = lib });
    exposed_blip.linkSystemLibrary("jxl", .{});
    exposed_blip.linkSystemLibrary("jxl_threads", .{});

    const exposed_mini_blar = b.addModule("mini_blar", .{
        .root_source_file = b.path("src/mini_blar.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "printable_binary", .module = pb_module },
            .{ .name = "z7z", .module = z7z_module },
            .{ .name = "bzip2z", .module = bzip2z_module },
        },
    });
    exposed_mini_blar.linkLibrary(lz4_lib);
    exposed_mini_blar.linkLibrary(zstdz_lib);
    if (jxl_include_path) |inc| exposed_mini_blar.addSystemIncludePath(.{ .cwd_relative = inc });
    if (jxl_lib_path) |lib| exposed_mini_blar.addLibraryPath(.{ .cwd_relative = lib });
    exposed_mini_blar.linkSystemLibrary("jxl", .{});
    exposed_mini_blar.linkSystemLibrary("jxl_threads", .{});

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
    // libjxl: executables linking this static lib need the library search path
    if (jxl_lib_path) |lib| static_lib.root_module.addLibraryPath(.{ .cwd_relative = lib });
    static_lib.root_module.linkSystemLibrary("jxl", .{});
    static_lib.root_module.linkSystemLibrary("jxl_threads", .{});
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
    if (jxl_lib_path) |lib| exe.root_module.addLibraryPath(.{ .cwd_relative = lib });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the benchmark CLI");
    run_step.dependOn(&run_cmd.step);

    // libmagic dependency — provides MIME-type detection for solid-mode sorting
    const magic_dep = b.dependency("libmagic", .{
        .target = target,
        .optimize = optimize,
    });
    const magic_lib = magic_dep.artifact("magic");

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
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-DHAVE_LIBMAGIC" },
    });
    blar.linkLibrary(static_lib);
    blar.linkLibrary(progrez_lib);
    blar.linkLibrary(magic_lib);
    blar.root_module.addIncludePath(b.path("src"));
    blar.root_module.addIncludePath(progrez_dep.path("include"));
    if (jxl_lib_path) |lib| blar.root_module.addLibraryPath(.{ .cwd_relative = lib });
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
    miniblar.linkLibrary(progrez_lib);
    miniblar.root_module.addIncludePath(b.path("src"));
    miniblar.root_module.addIncludePath(progrez_dep.path("include"));
    if (jxl_lib_path) |lib| miniblar.root_module.addLibraryPath(.{ .cwd_relative = lib });
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
    const unit_test_module = b.createModule(.{
        .root_source_file = b.path("src/blip.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "printable_binary", .module = pb_module },
            .{ .name = "z7z", .module = z7z_module },
            .{ .name = "bzip2z", .module = bzip2z_module },
        },
    });
    unit_test_module.linkLibrary(lz4_lib);
    unit_test_module.linkLibrary(zstdz_lib);
    if (jxl_include_path) |inc| unit_test_module.addSystemIncludePath(.{ .cwd_relative = inc });
    if (jxl_lib_path) |lib| unit_test_module.addLibraryPath(.{ .cwd_relative = lib });
    unit_test_module.linkSystemLibrary("jxl", .{});
    unit_test_module.linkSystemLibrary("jxl_threads", .{});
    const unit_tests = b.addTest(.{
        .root_module = unit_test_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // FFI tests (exercises lib.zig C FFI surface)
    const ffi_test_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "blip", .module = blip_module },
            .{ .name = "printable_binary", .module = pb_module },
            .{ .name = "z7z", .module = z7z_module },
            .{ .name = "bzip2z", .module = bzip2z_module },
        },
    });
    ffi_test_module.linkLibrary(lz4_lib);
    ffi_test_module.linkLibrary(zstdz_lib);
    if (jxl_include_path) |inc| ffi_test_module.addSystemIncludePath(.{ .cwd_relative = inc });
    if (jxl_lib_path) |lib| ffi_test_module.addLibraryPath(.{ .cwd_relative = lib });
    ffi_test_module.linkSystemLibrary("jxl", .{});
    ffi_test_module.linkSystemLibrary("jxl_threads", .{});
    const ffi_tests = b.addTest(.{
        .root_module = ffi_test_module,
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

    // compile-commands step — generates compile_commands.json for clangd/clang analysis
    const cc_gen = CompileCommandsGen.create(b, .{
        .src_include = b.path("src"),
        .progrez_include = progrez_dep.path("include"),
        .magic_include = magic_dep.path("src"),
    });
    const cc_step = b.step("compile-commands", "Generate compile_commands.json for clang tooling");
    cc_step.dependOn(&cc_gen.step);
}

/// Custom build step that generates compile_commands.json for C source files.
/// Resolves Zig dependency include paths to actual filesystem paths at build time.
const CompileCommandsGen = struct {
    step: std.Build.Step,
    src_include: std.Build.LazyPath,
    progrez_include: std.Build.LazyPath,
    magic_include: std.Build.LazyPath,

    const Options = struct {
        src_include: std.Build.LazyPath,
        progrez_include: std.Build.LazyPath,
        magic_include: std.Build.LazyPath,
    };

    fn create(b: *std.Build, opts: Options) *CompileCommandsGen {
        const self = b.allocator.create(CompileCommandsGen) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "generate compile_commands.json",
                .owner = b,
                .makeFn = make,
            }),
            .src_include = opts.src_include,
            .progrez_include = opts.progrez_include,
            .magic_include = opts.magic_include,
        };
        opts.src_include.addStepDependencies(&self.step);
        opts.progrez_include.addStepDependencies(&self.step);
        opts.magic_include.addStepDependencies(&self.step);
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *CompileCommandsGen = @fieldParentPtr("step", step);
        const b = step.owner;
        const alloc = b.allocator;

        const project_root = b.build_root.path orelse ".";
        const src_inc = try self.src_include.getPath3(b, step).toString(alloc);
        const progrez_inc = try self.progrez_include.getPath3(b, step).toString(alloc);
        const magic_inc = try self.magic_include.getPath3(b, step).toString(alloc);

        const content = try std.fmt.allocPrint(alloc,
            \\[
            \\  {{
            \\    "directory": "{s}",
            \\    "file": "src/blar.c",
            \\    "arguments": ["cc", "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-DHAVE_LIBMAGIC", "-I{s}", "-I{s}", "-I{s}", "src/blar.c"]
            \\  }},
            \\  {{
            \\    "directory": "{s}",
            \\    "file": "src/miniblar.c",
            \\    "arguments": ["cc", "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-I{s}", "-I{s}", "src/miniblar.c"]
            \\  }}
            \\]
            \\
        , .{
            project_root, src_inc, progrez_inc, magic_inc,
            project_root, src_inc, progrez_inc,
        });

        const out_path = try std.fs.path.join(alloc, &.{ project_root, "compile_commands.json" });
        var file = try std.fs.cwd().createFile(out_path, .{});
        defer file.close();
        try file.writeAll(content);
    }
};
