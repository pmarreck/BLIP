const std = @import("std");
const blip = @import("blip.zig");
const ct = @import("container_types.zig");
const checksum = @import("checksum.zig");
const testing = std.testing;

// Re-export v2 types from container_types
pub const AttributeSigil = ct.AttributeSigil;
pub const ContainerTypeId = ct.ContainerTypeId;
pub const CompressionId = ct.CompressionId;
pub const ChecksumId = ct.ChecksumId;
pub const checksumLength = ct.checksumLength;
pub const attrSentinel = ct.attrSentinel;
pub const parseAttrSigil = ct.parseAttrSigil;
pub const EncryptionId = ct.EncryptionId;
pub const KdfId = ct.KdfId;

pub const ContainerError = error{
    InvalidContainerType,
    InvalidLength,
    LengthExceedsBounds,
    MissingRequiredKey,
    DuplicateKey,
    KeysNotSorted,
    HashMismatch,
    IndexOutOfBounds,
    InvalidMagic,
    BufferTooSmall,
    UnexpectedEndOfInput,
    Overflow,
    // v2 LP-specific errors (merged into ContainerError for backward compat)
    MissingSigil,
    InvalidSigilOrder,
    MissingDecompLen,
};

/// Error set for v2 LP container operations.
/// Now identical to ContainerError (LP errors merged in for compatibility).
pub const LPContainerError = ContainerError;

// =============================================================================
// v2 LP (Length-Payload) Container Format
// =============================================================================

/// Options for LP container creation (optional attributes).
pub const LPOptions = struct {
    comp_id: ?CompressionId = null,
    decomp_len: ?u64 = null,
    csum_id: ?ChecksumId = null,
    enc_id: ?ct.EncryptionId = null,
    kdf_id: ?ct.KdfId = null,
    enc_salt: ?[ct.ENC_SALT_LEN]u8 = null,
    enc_nonce: ?[12]u8 = null,
};

/// Parsed view of an LP container.
pub const LPContainerView = struct {
    total_length: u64,
    type_id: ContainerTypeId,
    comp_id: ?CompressionId,
    decomp_len: ?u64,
    csum_id: ?ChecksumId,
    enc_id: ?ct.EncryptionId,
    kdf_id: ?ct.KdfId,
    enc_salt: ?[ct.ENC_SALT_LEN]u8,
    enc_nonce: ?[12]u8,
    /// Byte offset from container start to first byte after VAL sentinel.
    val_offset: usize,
    /// Total bytes in VAL region (payload + checksum if present).
    val_size: usize,
    /// The full container buffer.
    buf: []const u8,

    /// Returns the payload excluding checksum bytes.
    pub fn payloadSlice(self: LPContainerView) []const u8 {
        const csum_len: usize = if (self.csum_id) |id| ct.checksumLength(id) else 0;
        return self.buf[self.val_offset .. self.val_offset + self.val_size - csum_len];
    }

    /// Returns checksum bytes (empty slice if no checksum).
    pub fn checksumSlice(self: LPContainerView) []const u8 {
        const csum_len: usize = if (self.csum_id) |id| ct.checksumLength(id) else 0;
        if (csum_len == 0) return self.buf[0..0];
        const end = self.val_offset + self.val_size;
        return self.buf[end - csum_len .. end];
    }

};

/// Compute the total self-referential length for an LP container.
///
/// The total length counts from its own first byte to the container's last byte.
/// Uses fixpoint iteration since the BLIP encoding of total_length is part of
/// the total length itself.
pub fn computeLPLength(type_id: ContainerTypeId, val_payload_size: u64, options: LPOptions) u64 {
    // Compute attribute overhead (excluding total_length encoding itself)
    var attr_overhead: u64 = 0;

    // TYPE sentinel (0x81 0x01) + BLIP(type_id) -- always present
    attr_overhead += 2 + blip.encodedSize(@intFromEnum(type_id));

    // COMP sentinel + BLIP(comp_id) -- optional
    if (options.comp_id) |comp_id| {
        attr_overhead += 2 + blip.encodedSize(@intFromEnum(comp_id));
    }

    // DECOMP_LEN sentinel + BLIP(decomp_len) -- required if COMP present
    if (options.decomp_len) |decomp_len| {
        attr_overhead += 2 + blip.encodedSize(decomp_len);
    }

    // CSUM sentinel + BLIP(csum_id) -- optional
    if (options.csum_id) |csum_id| {
        attr_overhead += 2 + blip.encodedSize(@intFromEnum(csum_id));
    }

    // ENC sentinel + BLIP(enc_id) + BLIP(kdf_id) + salt + nonce -- optional
    if (options.enc_id) |enc_id| {
        attr_overhead += 2 + blip.encodedSize(@intFromEnum(enc_id));
        attr_overhead += blip.encodedSize(@intFromEnum(options.kdf_id orelse .argon2id));
        attr_overhead += ct.ENC_SALT_LEN; // salt
        attr_overhead += ct.encNonceLength(enc_id); // nonce
    }

    // VAL sentinel (0x81 0x7F) -- always present
    attr_overhead += 2;

    // Checksum size (appended to VAL payload)
    const csum_size: u64 = if (options.csum_id) |id| ct.checksumLength(id) else 0;

    // Fixpoint: total = blip_size(total) + attr_overhead + val_payload_size + csum_size
    const base: u64 = attr_overhead + val_payload_size + csum_size;
    for (1..10) |l_bytes| {
        const total = base + l_bytes;
        if (blip.encodedSize(total) == l_bytes) return total;
    }
    unreachable;
}

/// Write the LP header into buf.
///
/// Writes: [BLIP(total_length)] [TYPE sentinel] [BLIP(type_id)]
///         [optional COMP, DECOMP_LEN, CSUM attrs] [VAL sentinel]
///
/// Returns the number of bytes written (the offset where the caller should
/// begin writing the VAL payload).
pub fn writeLPHeader(buf: []u8, type_id: ContainerTypeId, total_length: u64, options: LPOptions) LPContainerError!usize {
    var pos: usize = 0;

    // 1. BLIP(total_length)
    const len_bytes = blip.encode(total_length, buf[pos..]) catch return ContainerError.BufferTooSmall;
    pos += len_bytes;

    // 2. TYPE sentinel + BLIP(type_id)
    const type_sentinel = ct.attrSentinel(.type_attr);
    if (pos + 2 > buf.len) return ContainerError.BufferTooSmall;
    buf[pos] = type_sentinel[0];
    buf[pos + 1] = type_sentinel[1];
    pos += 2;
    const type_bytes = blip.encode(@intFromEnum(type_id), buf[pos..]) catch return ContainerError.BufferTooSmall;
    pos += type_bytes;

    // 3. COMP sentinel + BLIP(comp_id) -- optional
    if (options.comp_id) |comp_id| {
        const comp_sentinel = ct.attrSentinel(.comp);
        if (pos + 2 > buf.len) return ContainerError.BufferTooSmall;
        buf[pos] = comp_sentinel[0];
        buf[pos + 1] = comp_sentinel[1];
        pos += 2;
        const comp_bytes = blip.encode(@intFromEnum(comp_id), buf[pos..]) catch return ContainerError.BufferTooSmall;
        pos += comp_bytes;
    }

    // 4. DECOMP_LEN sentinel + BLIP(decomp_len) -- optional
    if (options.decomp_len) |decomp_len| {
        const decomp_sentinel = ct.attrSentinel(.decomp_len);
        if (pos + 2 > buf.len) return ContainerError.BufferTooSmall;
        buf[pos] = decomp_sentinel[0];
        buf[pos + 1] = decomp_sentinel[1];
        pos += 2;
        const decomp_bytes = blip.encode(decomp_len, buf[pos..]) catch return ContainerError.BufferTooSmall;
        pos += decomp_bytes;
    }

    // 5. CSUM sentinel + BLIP(csum_id) -- optional
    if (options.csum_id) |csum_id| {
        const csum_sentinel = ct.attrSentinel(.csum);
        if (pos + 2 > buf.len) return ContainerError.BufferTooSmall;
        buf[pos] = csum_sentinel[0];
        buf[pos + 1] = csum_sentinel[1];
        pos += 2;
        const csum_bytes = blip.encode(@intFromEnum(csum_id), buf[pos..]) catch return ContainerError.BufferTooSmall;
        pos += csum_bytes;
    }

    // 6. ENC sentinel + BLIP(enc_id) + BLIP(kdf_id) + salt + nonce -- optional
    if (options.enc_id) |enc_id| {
        const enc_sentinel = ct.attrSentinel(.enc);
        if (pos + 2 > buf.len) return ContainerError.BufferTooSmall;
        buf[pos] = enc_sentinel[0];
        buf[pos + 1] = enc_sentinel[1];
        pos += 2;
        const enc_bytes = blip.encode(@intFromEnum(enc_id), buf[pos..]) catch return ContainerError.BufferTooSmall;
        pos += enc_bytes;
        const kdf_id = options.kdf_id orelse .argon2id;
        const kdf_bytes = blip.encode(@intFromEnum(kdf_id), buf[pos..]) catch return ContainerError.BufferTooSmall;
        pos += kdf_bytes;
        // Write salt
        const salt = options.enc_salt orelse @as([ct.ENC_SALT_LEN]u8, @splat(0));
        @memcpy(buf[pos..][0..ct.ENC_SALT_LEN], &salt);
        pos += ct.ENC_SALT_LEN;
        // Write nonce
        const nonce_len = ct.encNonceLength(enc_id);
        const nonce = options.enc_nonce orelse @as([12]u8, @splat(0));
        @memcpy(buf[pos..][0..nonce_len], nonce[0..nonce_len]);
        pos += nonce_len;
    }

    // 7. VAL sentinel
    const val_sentinel = ct.attrSentinel(.val);
    if (pos + 2 > buf.len) return ContainerError.BufferTooSmall;
    buf[pos] = val_sentinel[0];
    buf[pos + 1] = val_sentinel[1];
    pos += 2;

    return pos;
}

/// Parse an LP container header from a buffer.
///
/// Expects buf to start at the container's first byte (BLIP total_length).
/// Returns an LPContainerView with all parsed attributes and the offset/size
/// of the VAL payload region.
pub fn parseLPHeader(buf: []const u8) LPContainerError!LPContainerView {
    if (buf.len < 4) return ContainerError.UnexpectedEndOfInput; // minimum: BLIP(total) + TYPE sentinel + type_id + VAL sentinel

    var pos: usize = 0;

    // 1. Decode BLIP(total_length)
    const len_result = blip.decode(buf[pos..]) catch |e| switch (e) {
        error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
        error.Overflow => return ContainerError.Overflow,
        error.BufferTooSmall => return ContainerError.BufferTooSmall,
    };
    const total_length = len_result.value;
    pos += len_result.bytes_read;

    if (total_length > buf.len) return ContainerError.LengthExceedsBounds;
    if (total_length < pos + 4) return ContainerError.InvalidLength; // need at least TYPE sentinel + type + VAL sentinel

    // Work within the declared total_length
    const container_buf = buf[0..@intCast(total_length)];

    // 2. TYPE sentinel must be next
    if (pos + 2 > container_buf.len) return ContainerError.UnexpectedEndOfInput;
    const type_sigil = ct.parseAttrSigil(container_buf[pos..]) orelse return error.MissingSigil;
    if (type_sigil != .type_attr) return error.InvalidSigilOrder;
    pos += 2;

    // Decode type_id
    const type_result = blip.decode(container_buf[pos..]) catch |e| switch (e) {
        error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
        error.Overflow => return ContainerError.Overflow,
        error.BufferTooSmall => return ContainerError.BufferTooSmall,
    };
    const type_id = std.enums.fromInt(ContainerTypeId, @as(u7, @truncate(type_result.value))) orelse
        return ContainerError.InvalidContainerType;
    pos += type_result.bytes_read;

    // 3. Scan for optional attributes in sorted sigil order
    var comp_id: ?CompressionId = null;
    var decomp_len: ?u64 = null;
    var csum_id: ?ChecksumId = null;
    var enc_id: ?ct.EncryptionId = null;
    var kdf_id: ?ct.KdfId = null;
    var enc_salt: ?[ct.ENC_SALT_LEN]u8 = null;
    var enc_nonce: ?[12]u8 = null;
    var last_sigil_value: u8 = @intFromEnum(AttributeSigil.type_attr);

    while (pos + 2 <= container_buf.len) {
        const sigil = ct.parseAttrSigil(container_buf[pos..]) orelse return error.MissingSigil;
        const sigil_value = @intFromEnum(sigil);

        // Enforce sorted order
        if (sigil_value <= last_sigil_value) return error.InvalidSigilOrder;

        // VAL sentinel terminates attribute scanning
        if (sigil == .val) {
            pos += 2; // skip VAL sentinel
            const val_offset = pos;
            const val_size = @as(usize, @intCast(total_length)) - val_offset;

            // Validate: if comp is present, decomp_len must be present
            if (comp_id != null and decomp_len == null) return error.MissingDecompLen;

            return LPContainerView{
                .total_length = total_length,
                .type_id = type_id,
                .comp_id = comp_id,
                .decomp_len = decomp_len,
                .csum_id = csum_id,
                .enc_id = enc_id,
                .kdf_id = kdf_id,
                .enc_salt = enc_salt,
                .enc_nonce = enc_nonce,
                .val_offset = val_offset,
                .val_size = val_size,
                .buf = container_buf,
            };
        }

        last_sigil_value = sigil_value;
        pos += 2; // skip sentinel

        // Parse attribute value
        switch (sigil) {
            .comp => {
                const comp_result = blip.decode(container_buf[pos..]) catch |e| switch (e) {
                    error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
                    error.Overflow => return ContainerError.Overflow,
                    error.BufferTooSmall => return ContainerError.BufferTooSmall,
                };
                comp_id = std.enums.fromInt(CompressionId, @as(u7, @truncate(comp_result.value))) orelse
                    return ContainerError.InvalidContainerType;
                pos += comp_result.bytes_read;
            },
            .decomp_len => {
                const decomp_result = blip.decode(container_buf[pos..]) catch |e| switch (e) {
                    error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
                    error.Overflow => return ContainerError.Overflow,
                    error.BufferTooSmall => return ContainerError.BufferTooSmall,
                };
                decomp_len = decomp_result.value;
                pos += decomp_result.bytes_read;
            },
            .csum => {
                const csum_result = blip.decode(container_buf[pos..]) catch |e| switch (e) {
                    error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
                    error.Overflow => return ContainerError.Overflow,
                    error.BufferTooSmall => return ContainerError.BufferTooSmall,
                };
                csum_id = std.enums.fromInt(ChecksumId, @as(u7, @truncate(csum_result.value))) orelse
                    return ContainerError.InvalidContainerType;
                pos += csum_result.bytes_read;
            },
            .enc => {
                // BLIP(enc_id)
                const enc_result = blip.decode(container_buf[pos..]) catch |e| switch (e) {
                    error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
                    error.Overflow => return ContainerError.Overflow,
                    error.BufferTooSmall => return ContainerError.BufferTooSmall,
                };
                enc_id = std.enums.fromInt(ct.EncryptionId, @as(u7, @truncate(enc_result.value))) orelse
                    return ContainerError.InvalidContainerType;
                pos += enc_result.bytes_read;

                // BLIP(kdf_id)
                const kdf_result = blip.decode(container_buf[pos..]) catch |e| switch (e) {
                    error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
                    error.Overflow => return ContainerError.Overflow,
                    error.BufferTooSmall => return ContainerError.BufferTooSmall,
                };
                kdf_id = std.enums.fromInt(ct.KdfId, @as(u7, @truncate(kdf_result.value))) orelse
                    return ContainerError.InvalidContainerType;
                pos += kdf_result.bytes_read;

                // 16-byte salt
                if (pos + ct.ENC_SALT_LEN > container_buf.len) return ContainerError.UnexpectedEndOfInput;
                var salt_buf: [ct.ENC_SALT_LEN]u8 = undefined;
                @memcpy(&salt_buf, container_buf[pos..][0..ct.ENC_SALT_LEN]);
                enc_salt = salt_buf;
                pos += ct.ENC_SALT_LEN;

                // nonce (length depends on enc_id)
                const nonce_len = ct.encNonceLength(enc_id.?);
                if (pos + nonce_len > container_buf.len) return ContainerError.UnexpectedEndOfInput;
                var nonce_buf: [12]u8 = .{0} ** 12;
                @memcpy(nonce_buf[0..nonce_len], container_buf[pos..][0..nonce_len]);
                enc_nonce = nonce_buf;
                pos += nonce_len;
            },
            .seg => {
                // SEG payload is exactly 3 BLIP scalars: I, M, N (where N may be NIL).
                // Skip past all three; the actual values are parsed by Layer-3
                // segmentation reassembly code, not the LP-walk here.
                inline for (0..3) |_| {
                    const r = blip.decodeScalar(container_buf[pos..]) catch |e| switch (e) {
                        error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
                        error.Overflow => return ContainerError.Overflow,
                        error.BufferTooSmall => return ContainerError.BufferTooSmall,
                    };
                    pos += r.bytes_read;
                }
            },
            .sig => {
                // Future: skip sig bytes. For now, we don't know the length
                // so we can't parse past it. Return error.
                return error.MissingSigil;
            },
            .type_attr, .val => unreachable, // handled above
        }
    }

    // If we exit the loop without finding VAL sentinel
    return error.MissingSigil;
}

// =============================================================================
// v2 LP Tests
// =============================================================================

test "computeLPLength for simple container (TYPE + VAL only, UTF8 hello)" {
    // UTF8 "hello" (5 bytes), no options
    // attr_overhead = 2 (TYPE sentinel) + 1 (BLIP(3)) + 2 (VAL sentinel) = 5
    // total = blip_size(total) + 5 + 5 = blip_size(total) + 10
    // Try total = 1 + 10 = 11. blip_size(11) = 1. Yes!
    try testing.expectEqual(@as(u64, 11), computeLPLength(.utf8, 5, .{}));
}

test "computeLPLength for empty value" {
    // DATA, 0 bytes payload, no options
    // attr_overhead = 2 + 1 (BLIP(4)) + 2 = 5
    // total = blip_size(total) + 5 + 0 = blip_size(total) + 5
    // Try total = 1 + 5 = 6. blip_size(6) = 1. Yes!
    try testing.expectEqual(@as(u64, 6), computeLPLength(.data, 0, .{}));
}

test "computeLPLength with CSUM BLAKE3-128" {
    // UTF8 "hello" (5 bytes) + BLAKE3-128 checksum (16 bytes)
    // attr_overhead = 2+1 (TYPE) + 2+1 (CSUM) + 2 (VAL) = 8
    // total = blip_size(total) + 8 + 5 + 16 = blip_size(total) + 29
    // Try total = 1 + 29 = 30. blip_size(30) = 1. Yes!
    try testing.expectEqual(@as(u64, 30), computeLPLength(.utf8, 5, .{ .csum_id = .blake3_128 }));
}

test "computeLPLength with CSUM CRC32" {
    // UTF8 "hello" (5 bytes) + CRC32 checksum (4 bytes)
    // attr_overhead = 2+1 (TYPE) + 2+1 (CSUM) + 2 (VAL) = 8
    // total = blip_size(total) + 8 + 5 + 4 = blip_size(total) + 17
    // Try total = 1 + 17 = 18. blip_size(18) = 1. Yes!
    try testing.expectEqual(@as(u64, 18), computeLPLength(.utf8, 5, .{ .csum_id = .crc32 }));
}

test "computeLPLength with COMP + DECOMP_LEN" {
    // DATA 2000 bytes compressed, decomp_len=10000, no checksum
    // attr_overhead = 2+1 (TYPE=4) + 2+1 (COMP=1) + 2+3 (DECOMP_LEN=10000, blip_size=3) + 2 (VAL) = 13
    // total = blip_size(total) + 13 + 2000 = blip_size(total) + 2013
    // blip_size(2016) = 3 (value > 255, <= 65535). total = 3 + 2013 = 2016.
    try testing.expectEqual(@as(u64, 2016), computeLPLength(.data, 2000, .{ .comp_id = .lzma2, .decomp_len = 10000 }));
}

test "computeLPLength with COMP + DECOMP_LEN + CSUM" {
    // DATA 2000 bytes compressed, decomp_len=10000, BLAKE3-128 checksum (16 bytes)
    // attr_overhead = 2+1 (TYPE=4) + 2+1 (COMP=1) + 2+3 (DECOMP_LEN=10000) + 2+1 (CSUM=3) + 2 (VAL) = 16
    // total = blip_size(total) + 16 + 2000 + 16 = blip_size(total) + 2032
    // blip_size(2035) = 3. total = 3 + 2032 = 2035.
    try testing.expectEqual(@as(u64, 2035), computeLPLength(.data, 2000, .{
        .comp_id = .lzma2,
        .decomp_len = 10000,
        .csum_id = .blake3_128,
    }));
}

test "writeLPHeader + parseLPHeader round-trip simple (TYPE + VAL only)" {
    var buf: [128]u8 = undefined;
    const payload = "hello";
    const total = computeLPLength(.utf8, payload.len, .{});
    const header_size = try writeLPHeader(&buf, .utf8, total, .{});

    // Write payload
    @memcpy(buf[header_size .. header_size + payload.len], payload);

    // Parse back
    const view = try parseLPHeader(&buf);
    try testing.expectEqual(@as(u64, total), view.total_length);
    try testing.expectEqual(ContainerTypeId.utf8, view.type_id);
    try testing.expectEqual(@as(?CompressionId, null), view.comp_id);
    try testing.expectEqual(@as(?u64, null), view.decomp_len);
    try testing.expectEqual(@as(?ChecksumId, null), view.csum_id);
    try testing.expectEqual(header_size, view.val_offset);
    try testing.expectEqual(@as(usize, payload.len), view.val_size);

    // Verify payload round-trips
    try testing.expectEqualSlices(u8, payload, view.payloadSlice());
    try testing.expectEqual(@as(usize, 0), view.checksumSlice().len);
}

test "writeLPHeader + parseLPHeader round-trip with CSUM (BLAKE3-128)" {
    var buf: [128]u8 = undefined;
    const payload = "hello";
    const opts = LPOptions{ .csum_id = .blake3_128 };
    const total = computeLPLength(.utf8, payload.len, opts);
    const header_size = try writeLPHeader(&buf, .utf8, total, opts);

    // Write payload
    @memcpy(buf[header_size .. header_size + payload.len], payload);

    // Write checksum (covers bytes[0..total - 16])
    const csum_len = ct.checksumLength(.blake3_128);
    const csum_offset = @as(usize, @intCast(total)) - csum_len;
    const hash = checksum.compute(.blake3_128, buf[0..csum_offset]);
    @memcpy(buf[csum_offset..@intCast(total)], hash[0..csum_len]);

    // Parse back
    const view = try parseLPHeader(&buf);
    try testing.expectEqual(@as(u64, total), view.total_length);
    try testing.expectEqual(ContainerTypeId.utf8, view.type_id);
    try testing.expectEqual(@as(?CompressionId, null), view.comp_id);
    try testing.expectEqual(@as(?u64, null), view.decomp_len);
    try testing.expectEqual(@as(?ChecksumId, .blake3_128), view.csum_id);
    try testing.expectEqual(header_size, view.val_offset);
    try testing.expectEqual(@as(usize, payload.len + csum_len), view.val_size);

    // Verify payload and checksum slices
    try testing.expectEqualSlices(u8, payload, view.payloadSlice());
    try testing.expectEqual(@as(usize, 16), view.checksumSlice().len);
}

test "writeLPHeader + parseLPHeader round-trip with COMP + DECOMP_LEN + CSUM" {
    var buf: [4096]u8 = undefined;
    const compressed_size: usize = 100;
    const decomp_len: u64 = 10000;
    const opts = LPOptions{
        .comp_id = .lzma2,
        .decomp_len = decomp_len,
        .csum_id = .blake3_128,
    };
    const total = computeLPLength(.data, compressed_size, opts);
    const header_size = try writeLPHeader(&buf, .data, total, opts);

    // Write fake compressed payload
    @memset(buf[header_size .. header_size + compressed_size], 0xAA);

    // Write checksum
    const csum_len = ct.checksumLength(.blake3_128);
    const csum_offset = @as(usize, @intCast(total)) - csum_len;
    const hash = checksum.compute(.blake3_128, buf[0..csum_offset]);
    @memcpy(buf[csum_offset..@intCast(total)], hash[0..csum_len]);

    // Parse back
    const view = try parseLPHeader(&buf);
    try testing.expectEqual(@as(u64, total), view.total_length);
    try testing.expectEqual(ContainerTypeId.data, view.type_id);
    try testing.expectEqual(@as(?CompressionId, .lzma2), view.comp_id);
    try testing.expectEqual(@as(?u64, decomp_len), view.decomp_len);
    try testing.expectEqual(@as(?ChecksumId, .blake3_128), view.csum_id);
    try testing.expectEqual(header_size, view.val_offset);
    try testing.expectEqual(@as(usize, compressed_size + csum_len), view.val_size);

    // Verify payload slice is just the compressed data
    const ps = view.payloadSlice();
    try testing.expectEqual(@as(usize, compressed_size), ps.len);
    for (ps) |b| {
        try testing.expectEqual(@as(u8, 0xAA), b);
    }

    // Verify checksum slice
    try testing.expectEqual(@as(usize, 16), view.checksumSlice().len);
}

test "parseLPHeader rejects too-short buffer" {
    const result = parseLPHeader(&[_]u8{0x03});
    try testing.expectError(error.UnexpectedEndOfInput, result);
}

test "parseLPHeader rejects missing TYPE sigil" {
    // total_length=7, then COMP sigil (0x10) instead of TYPE (0x01)
    const result = parseLPHeader(&[_]u8{ 7, 0x81, 0x10, 0x01, 0x81, 0x7F, 0x00 });
    try testing.expectError(error.InvalidSigilOrder, result);
}

test "parseLPHeader rejects invalid sigil order (CSUM before COMP)" {
    // BLIP(20) + TYPE=utf8 + CSUM (0x12) then COMP (0x10) -- wrong order
    // CSUM=0x12 > TYPE=0x01, so CSUM is accepted. Then COMP=0x10 < CSUM=0x12, so order violated.
    var buf: [32]u8 = undefined;
    buf[0] = 20; // total_length
    buf[1] = 0x81;
    buf[2] = 0x01; // TYPE sentinel
    buf[3] = 3; // utf8
    buf[4] = 0x81;
    buf[5] = 0x12; // CSUM sentinel
    buf[6] = 1; // crc32
    buf[7] = 0x81;
    buf[8] = 0x10; // COMP sentinel -- 0x10 < 0x12, order violation
    buf[9] = 1; // lzma2
    buf[10] = 0x81;
    buf[11] = 0x7F; // VAL
    const result = parseLPHeader(&buf);
    try testing.expectError(error.InvalidSigilOrder, result);
}

test "parseLPHeader rejects COMP without DECOMP_LEN" {
    // Build a buffer with COMP but no DECOMP_LEN
    var buf: [32]u8 = undefined;
    buf[0] = 12; // total_length
    buf[1] = 0x81;
    buf[2] = 0x01; // TYPE
    buf[3] = 4; // data
    buf[4] = 0x81;
    buf[5] = 0x10; // COMP
    buf[6] = 1; // lzma2
    buf[7] = 0x81;
    buf[8] = 0x7F; // VAL
    // payload: buf[9..12] = 3 bytes
    buf[9] = 0x00;
    buf[10] = 0x00;
    buf[11] = 0x00;
    const result = parseLPHeader(&buf);
    try testing.expectError(error.MissingDecompLen, result);
}

test "LPContainerView payloadSlice and checksumSlice with CRC32" {
    var buf: [64]u8 = undefined;
    const payload = "test";
    const opts = LPOptions{ .csum_id = .crc32 };
    const total = computeLPLength(.utf8, payload.len, opts);
    const header_size = try writeLPHeader(&buf, .utf8, total, opts);

    // Write payload
    @memcpy(buf[header_size .. header_size + payload.len], payload);

    // Write CRC32 checksum (4 bytes)
    const csum_len = ct.checksumLength(.crc32);
    const csum_offset = @as(usize, @intCast(total)) - csum_len;
    const hash = checksum.compute(.crc32, buf[0..csum_offset]);
    @memcpy(buf[csum_offset..@intCast(total)], hash[0..csum_len]);

    const view = try parseLPHeader(&buf);

    // payloadSlice should be just "test"
    try testing.expectEqualSlices(u8, payload, view.payloadSlice());

    // checksumSlice should be 4 bytes
    try testing.expectEqual(@as(usize, 4), view.checksumSlice().len);

    // Verify the checksum is valid
    try testing.expect(checksum.verify(.crc32, buf[0..csum_offset], view.checksumSlice()));
}

test "full round-trip with actual checksum verification (BLAKE3-128)" {
    var buf: [256]u8 = undefined;
    const payload = "The quick brown fox jumps over the lazy dog";
    const opts = LPOptions{ .csum_id = .blake3_128 };
    const total = computeLPLength(.utf8, payload.len, opts);

    // Write header
    const header_size = try writeLPHeader(&buf, .utf8, total, opts);

    // Write payload
    @memcpy(buf[header_size .. header_size + payload.len], payload);

    // Compute and write checksum over everything before checksum
    const csum_len = ct.checksumLength(.blake3_128);
    const csum_offset = @as(usize, @intCast(total)) - csum_len;
    const hash = checksum.compute(.blake3_128, buf[0..csum_offset]);
    @memcpy(buf[csum_offset..@intCast(total)], hash[0..csum_len]);

    // Parse back
    const view = try parseLPHeader(&buf);

    // Verify payload
    try testing.expectEqualSlices(u8, payload, view.payloadSlice());

    // Verify checksum by recomputing
    const verify_hash = checksum.compute(.blake3_128, buf[0..csum_offset]);
    try testing.expectEqualSlices(u8, view.checksumSlice(), verify_hash[0..csum_len]);

    // Verify using checksum.verify
    try testing.expect(checksum.verify(.blake3_128, buf[0..csum_offset], view.checksumSlice()));
}

test "full round-trip with xxHash64 checksum" {
    var buf: [256]u8 = undefined;
    const payload = "hello world";
    const opts = LPOptions{ .csum_id = .xxhash64 };
    const total = computeLPLength(.data, payload.len, opts);

    const header_size = try writeLPHeader(&buf, .data, total, opts);
    @memcpy(buf[header_size .. header_size + payload.len], payload);

    const csum_len = ct.checksumLength(.xxhash64);
    const csum_offset = @as(usize, @intCast(total)) - csum_len;
    const hash = checksum.compute(.xxhash64, buf[0..csum_offset]);
    @memcpy(buf[csum_offset..@intCast(total)], hash[0..csum_len]);

    const view = try parseLPHeader(&buf);
    try testing.expectEqual(ContainerTypeId.data, view.type_id);
    try testing.expectEqualSlices(u8, payload, view.payloadSlice());
    try testing.expectEqual(@as(usize, 8), view.checksumSlice().len);
    try testing.expect(checksum.verify(.xxhash64, buf[0..csum_offset], view.checksumSlice()));
}

test "computeLPLength at BLIP boundary crossing" {
    // Find a case where adding the BLIP length encoding pushes total past 127
    // attr_overhead for array + no options = 2+1+2 = 5
    // total = blip_size(total) + 5 + val_size
    // If val_size = 121: total = 1 + 5 + 121 = 127. blip_size(127) = 1. total = 127.
    try testing.expectEqual(@as(u64, 127), computeLPLength(.array, 121, .{}));

    // If val_size = 122: total = 1 + 5 + 122 = 128. blip_size(128) = 2. Nope.
    //                     total = 2 + 5 + 122 = 129. blip_size(129) = 2. Yes!
    try testing.expectEqual(@as(u64, 129), computeLPLength(.array, 122, .{}));
}

test "parseLPHeader rejects length exceeding buffer" {
    // BLIP(100) but buffer is only 10 bytes
    var buf: [10]u8 = undefined;
    buf[0] = 100;
    buf[1] = 0x81;
    buf[2] = 0x01;
    buf[3] = 3;
    const result = parseLPHeader(&buf);
    try testing.expectError(error.LengthExceedsBounds, result);
}

test "writeLPHeader returns correct offset for all container types" {
    var buf: [128]u8 = undefined;
    // For each container type, the header should write correctly
    inline for (std.meta.fields(ContainerTypeId)) |field| {
        const type_id: ContainerTypeId = @enumFromInt(field.value);
        const total = computeLPLength(type_id, 10, .{});
        const header_size = try writeLPHeader(&buf, type_id, total, .{});
        const view = try parseLPHeader(&buf);
        try testing.expectEqual(type_id, view.type_id);
        try testing.expectEqual(header_size, view.val_offset);
    }
}

test "LP container with ENC attribute round-trips" {
    const allocator = testing.allocator;
    const payload = "secret data";

    var salt: [16]u8 = undefined;
    @memset(&salt, 0xAA);
    var nonce: [12]u8 = undefined;
    @memset(&nonce, 0xBB);

    const opts = LPOptions{
        .enc_id = .aes_256_gcm,
        .kdf_id = .argon2id,
        .enc_salt = salt,
        .enc_nonce = nonce,
    };
    const total = computeLPLength(.data, payload.len, opts);
    const buf = try allocator.alloc(u8, @intCast(total));
    defer allocator.free(buf);

    const header_len = try writeLPHeader(buf, .data, total, opts);
    @memcpy(buf[header_len..][0..payload.len], payload);

    const view = try parseLPHeader(buf);
    try testing.expectEqual(@as(?ct.EncryptionId, .aes_256_gcm), view.enc_id);
    try testing.expectEqual(@as(?ct.KdfId, .argon2id), view.kdf_id);
    try testing.expectEqualSlices(u8, &salt, &view.enc_salt.?);
    try testing.expectEqualSlices(u8, &nonce, &view.enc_nonce.?);
    try testing.expectEqualSlices(u8, payload, view.payloadSlice());
}

test "ENC attribute overhead is correct" {
    var salt: [16]u8 = undefined;
    @memset(&salt, 0);
    var nonce: [12]u8 = undefined;
    @memset(&nonce, 0);

    const with_enc = computeLPLength(.data, 10, .{
        .enc_id = .aes_256_gcm,
        .kdf_id = .argon2id,
        .enc_salt = salt,
        .enc_nonce = nonce,
    });
    const without_enc = computeLPLength(.data, 10, .{});
    // Difference should be 32 bytes (2 sentinel + 1 enc_id + 1 kdf_id + 16 salt + 12 nonce)
    try testing.expectEqual(@as(u64, 32), with_enc - without_enc);
}

test "LP container with ENC + CSUM round-trips" {
    const allocator = testing.allocator;
    const payload = "encrypted with checksum";

    var salt: [16]u8 = undefined;
    @memset(&salt, 0xCC);
    var nonce: [12]u8 = undefined;
    @memset(&nonce, 0xDD);

    const opts = LPOptions{
        .csum_id = .blake3_128,
        .enc_id = .chacha20_poly1305,
        .kdf_id = .pbkdf2_sha256,
        .enc_salt = salt,
        .enc_nonce = nonce,
    };
    const total = computeLPLength(.data, payload.len, opts);
    const buf = try allocator.alloc(u8, @intCast(total));
    defer allocator.free(buf);

    const header_len = try writeLPHeader(buf, .data, total, opts);
    @memcpy(buf[header_len..][0..payload.len], payload);

    // Write checksum
    const csum_len = ct.checksumLength(.blake3_128);
    const csum_offset = @as(usize, @intCast(total)) - csum_len;
    const hash = checksum.compute(.blake3_128, buf[0..csum_offset]);
    @memcpy(buf[csum_offset..@intCast(total)], hash[0..csum_len]);

    const view = try parseLPHeader(buf);
    try testing.expectEqual(@as(?ChecksumId, .blake3_128), view.csum_id);
    try testing.expectEqual(@as(?ct.EncryptionId, .chacha20_poly1305), view.enc_id);
    try testing.expectEqual(@as(?ct.KdfId, .pbkdf2_sha256), view.kdf_id);
    try testing.expectEqualSlices(u8, &salt, &view.enc_salt.?);
    try testing.expectEqualSlices(u8, &nonce, &view.enc_nonce.?);
    try testing.expectEqualSlices(u8, payload, view.payloadSlice());
    try testing.expect(checksum.verify(.blake3_128, buf[0..csum_offset], view.checksumSlice()));
}

test "existing containers without ENC still parse (enc fields null)" {
    var buf: [128]u8 = undefined;
    const payload = "no encryption";
    const total = computeLPLength(.utf8, payload.len, .{});
    const header_size = try writeLPHeader(&buf, .utf8, total, .{});
    @memcpy(buf[header_size .. header_size + payload.len], payload);

    const view = try parseLPHeader(&buf);
    try testing.expectEqual(@as(?ct.EncryptionId, null), view.enc_id);
    try testing.expectEqual(@as(?ct.KdfId, null), view.kdf_id);
    try testing.expectEqual(@as(?[ct.ENC_SALT_LEN]u8, null), view.enc_salt);
    try testing.expectEqual(@as(?[12]u8, null), view.enc_nonce);
    try testing.expectEqualSlices(u8, payload, view.payloadSlice());
}

test {
    _ = @import("container_types.zig");
}
