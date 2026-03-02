# Request: Expose named modules for downstream consumers

**From**: entropy_shield
**Date**: 2026-02-24

## Issue

BLIP's `build.zig` creates `blip_module` and `pb_module` using `b.createModule()`, which makes them local to the BLIP build. Downstream Zig consumers using `b.dependency("blip", ...).module("blip")` will fail because no named modules are registered via `b.addModule()`.

## Current workaround

entropy_shield creates its own module pointing at `blip_dep.path("src/mini_blar.zig")` directly. This works because `mini_blar.zig`'s transitive imports (`blip.zig`, `container.zig`, `leaf.zig`, `array.zig`, `dict.zig`, `data.zig`, `container_types.zig`) are all file-relative within `src/` and none of them need the `printable_binary` named import.

## Suggested fix

Add named module exports to BLIP's `build.zig`:

```zig
// After creating blip_module and pb_module, register them for consumers:
_ = b.addModule("blip", .{
    .root_source_file = b.path("src/blip.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "printable_binary", .module = pb_module },
    },
});

_ = b.addModule("mini_blar", .{
    .root_source_file = b.path("src/mini_blar.zig"),
    .target = target,
    .optimize = optimize,
});
```

This would let consumers do:
```zig
const blip_dep = b.dependency("blip", .{ .target = target, .optimize = optimize });
const mini_blar_mod = blip_dep.module("mini_blar");
```

## Also: relative vs absolute paths

entropy_shield will use `mini_blar` with **relative paths** (relative to the repo root) in `FileEntry.path`. The `mini_blar` API is path-agnostic — it stores whatever string you give it — but it's worth documenting that paths should be relative for portability, not absolute filesystem paths.
