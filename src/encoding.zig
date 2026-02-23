//! Common interface for all variable-length integer encodings.
//! Allows benchmark code to iterate over encodings generically.

const std = @import("std");

// Re-export all encoding modules for convenient access.
pub const blip = @import("blip.zig");
pub const leb128 = @import("leb128.zig");
pub const protobuf = @import("protobuf_varint.zig");
pub const asn1 = @import("asn1_length.zig");
pub const prefix_varint = @import("prefix_varint.zig");
pub const sqlite = @import("sqlite_varint.zig");

/// Tuple of all encoding modules that implement the common interface
/// (name, encode, decode, DecodeResult, Error), for comptime iteration
/// in benchmarks and cross-encoding tests.
pub const all_encodings = .{
    blip,
    leb128,
    protobuf,
    asn1,
    prefix_varint,
    sqlite,
};

/// The common result type (each encoding has its own, but they're structurally identical).
pub const DecodeResult = struct {
    value: u64,
    bytes_read: usize,
};

/// The common error type (union of all encoding errors).
pub const Error = error{
    BufferTooSmall,
    UnexpectedEndOfInput,
    Overflow,
};

// =============================================================================
// Tests
// =============================================================================

test "all encodings roundtrip" {
    const values = [_]u64{
        0, 1, 42, 127, 128, 200, 255, 256, 300, 1000,
        16383, 16384, 50000, 65535, 65536,
        0xFFFFFF, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF,
    };

    inline for (all_encodings) |Enc| {
        for (values) |v| {
            var buf: [16]u8 = undefined;
            const n = Enc.encode(v, &buf) catch continue;
            const result = Enc.decode(buf[0..n]) catch continue;
            try std.testing.expectEqual(v, result.value);
            try std.testing.expectEqual(n, result.bytes_read);
        }
    }
}

test "all encodings have names" {
    inline for (all_encodings) |Enc| {
        try std.testing.expect(Enc.name.len > 0);
    }
}
