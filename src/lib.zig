const blip = @import("blip");

// C FFI surface for BLIP encoding/decoding.
// All public C API functions will be defined here using `export fn`.

// Re-export blip module for internal use
pub const core = blip;

// Placeholder: export functions will go here
// e.g. export fn blip_encode(...) ...

test "lib placeholder" {
    _ = blip;
}
