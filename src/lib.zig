const blip = @import("blip");

// C FFI surface for BLIP encoding/decoding.
// All public C API functions are defined here using `export fn`.

// Re-export blip module for internal use
pub const core = blip;

/// Encode a u64 value into BLIP format.
/// Returns number of bytes written, or -1 on error.
export fn blip_encode(value: u64, out_buf: [*]u8, out_cap: usize) callconv(.c) i32 {
    const buf = out_buf[0..out_cap];
    const n = blip.encode(value, buf) catch return -1;
    return @intCast(n);
}

/// Decode a BLIP value from encoded bytes.
/// Returns bytes consumed, or -1 on error. Decoded value stored in out_value.
export fn blip_decode(encoded: [*]const u8, encoded_len: usize, out_value: *u64) callconv(.c) i32 {
    const buf = encoded[0..encoded_len];
    const result = blip.decode(buf) catch return -1;
    out_value.* = result.value;
    return @intCast(result.bytes_read);
}

/// Check if encoded bytes represent a sentinel.
export fn blip_is_sentinel(encoded: [*]const u8, encoded_len: usize) callconv(.c) bool {
    return blip.isSentinel(encoded[0..encoded_len]);
}

/// Get the encoded size for a value without actually encoding.
export fn blip_encoded_size(value: u64) callconv(.c) i32 {
    var buf: [16]u8 = undefined;
    const n = blip.encode(value, &buf) catch return -1;
    return @intCast(n);
}

test "lib placeholder" {
    _ = blip;
}
