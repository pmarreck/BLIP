const std = @import("std");

// BLIP: Byte Length Integer Prefix encoding
// See BLIP_SPEC.md for the full specification.

test "placeholder" {
    try std.testing.expect(true);
}

// Pull in tests from other encoding modules
test {
    _ = @import("leb128.zig");
    _ = @import("protobuf_varint.zig");
}
