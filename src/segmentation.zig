// =============================================================================
// BLIP Segmentation (v3) — reassembly of multi-segment streams
// =============================================================================
// SEGMENT containers (TYPE=9) wrap slices of a larger BLIP byte stream.  This
// module handles the producer-side serializeSegment and consumer-side
// parseSegment / reassemble routines.  See BLIP_WIRE_SPEC.md §Segmentation
// for the wire format and reassembly algorithm.
// =============================================================================

const std = @import("std");
const blip = @import("blip.zig");
const ct = @import("container_types.zig");
const container = @import("container.zig");
const checksum = @import("checksum.zig");

const Allocator = std.mem.Allocator;

pub const SegError = error{
    NotASegment,
    InvalidSegment,
    InconsistentTotal,
    MissingSegments,
    SequenceGap,
    DuplicateSegmentValueMismatch,
    BufferTooSmall,
} || Allocator.Error || container.ContainerError;

/// Parsed view of one SEGMENT container.
pub const SegInfo = struct {
    stream_id: u64,
    /// 1-based segment index (M=1 is the first segment).  M=0 is illegal in v3.
    seg_index: u64,
    /// total segment count, or null when the SEG N field carries the NIL sentinel
    total: ?u64,
    /// Slice of `buf` that holds the reassembly payload (VAL minus checksum bytes if CSUM present).
    val: []const u8,
    /// Checksum algorithm id, if a CSUM attribute was present.
    csum_id: ?ct.ChecksumId,
    /// Checksum bytes from the end of the VAL payload (empty if csum_id is null).
    csum_bytes: []const u8,
};

/// Parse a SEGMENT container.  Errors if the container's TYPE is not 9.
pub fn parseSegment(buf: []const u8) SegError!SegInfo {
    const view = try container.parseLPHeader(buf);
    if (view.type_id != .segment) return error.NotASegment;

    // Walk attributes again to find SEG values.  parseLPHeader already validated
    // the LP envelope and skipped past SEG, but didn't capture (I, M, N).
    var pos: usize = 0;
    // skip Length BLIP
    const len_r = try blip.decode(buf[pos..]);
    pos += len_r.bytes_read;
    // skip TYPE sentinel + type_id BLIP
    pos += 2;
    const tr = try blip.decode(buf[pos..]);
    pos += tr.bytes_read;

    var found_seg = false;
    var I: u64 = 0;
    var M: u64 = 0;
    var N: ?u64 = null;

    while (pos + 2 <= buf.len) {
        const sigil = ct.parseAttrSigil(buf[pos..]) orelse return container.ContainerError.MissingSigil;
        if (sigil == .val) break;
        pos += 2;
        switch (sigil) {
            .seg => {
                const r1 = try blip.decode(buf[pos..]);
                I = r1.value;
                pos += r1.bytes_read;
                const r2 = try blip.decode(buf[pos..]);
                M = r2.value;
                pos += r2.bytes_read;
                const r3 = try blip.decodeScalar(buf[pos..]);
                switch (r3.scalar) {
                    .integer => |v| N = v,
                    .nil => N = null,
                    .boolean => return error.InvalidSegment,
                }
                pos += r3.bytes_read;
                found_seg = true;
            },
            else => {
                // For the other attributes we don't care about values here;
                // parseLPHeader has captured them in `view`.  Skip generically by
                // re-decoding their payload structure.
                pos = try skipAttributePayload(buf, pos, sigil);
            },
        }
    }

    if (!found_seg) return error.InvalidSegment;

    // VAL slice (minus checksum bytes if CSUM present)
    const val_full = buf[view.val_offset..][0..view.val_size];
    var val_payload = val_full;
    var csum_bytes: []const u8 = &.{};
    if (view.csum_id) |cid| {
        const clen = ct.checksumLength(cid);
        if (val_full.len < clen) return error.InvalidSegment;
        val_payload = val_full[0 .. val_full.len - clen];
        csum_bytes = val_full[val_full.len - clen ..];
    }

    return SegInfo{
        .stream_id = I,
        .seg_index = M,
        .total = N,
        .val = val_payload,
        .csum_id = view.csum_id,
        .csum_bytes = csum_bytes,
    };
}

fn skipAttributePayload(buf: []const u8, start: usize, sigil: ct.AttributeSigil) !usize {
    var pos = start;
    switch (sigil) {
        .comp, .csum => {
            const r = try blip.decode(buf[pos..]);
            pos += r.bytes_read;
        },
        .decomp_len => {
            const r = try blip.decode(buf[pos..]);
            pos += r.bytes_read;
        },
        .enc => {
            // enc_id, kdf_id, 16-byte salt, 12-byte nonce
            const r1 = try blip.decode(buf[pos..]);
            pos += r1.bytes_read;
            const r2 = try blip.decode(buf[pos..]);
            pos += r2.bytes_read;
            pos += ct.ENC_SALT_LEN;
            pos += 12; // nonce length (both AEADs use 12)
        },
        .seg, .sig, .type_attr, .val => return error.InvalidSegment,
    }
    return pos;
}

/// Serialize one SEGMENT container with the given (I, M, N) and VAL bytes.
/// `total = null` means N=NIL (streaming).  Caller owns the returned slice.
/// If `csum_id` is non-null, appends the corresponding checksum to VAL.
pub fn serializeSegment(
    allocator: Allocator,
    stream_id: u64,
    seg_index: u64,
    total: ?u64,
    val: []const u8,
    csum_id: ?ct.ChecksumId,
) SegError![]u8 {
    // Compute SEG attribute payload size: sigil(2) + I + M + N
    const seg_i_size = blip.encodedSize(stream_id);
    const seg_m_size = blip.encodedSize(seg_index);
    const seg_n_size = if (total) |n| blip.encodedSize(n) else 2; // NIL = 2 bytes
    const seg_attr_size = 2 + seg_i_size + seg_m_size + seg_n_size;

    const csum_attr_size: usize = if (csum_id != null) 2 + 1 else 0; // sigil + BLIP(id) (id < 128)
    const csum_bytes_size: usize = if (csum_id) |c| ct.checksumLength(c) else 0;

    // VAL payload (with checksum appended) size
    const val_total = val.len + csum_bytes_size;

    // Compute total LP envelope length
    // attr area: TYPE(3) + [CSUM] + SEG + VAL_sentinel(2)
    const type_attr = 2 + 1; // sentinel(2) + BLIP(9)=1
    const attrs = type_attr + csum_attr_size + seg_attr_size + 2;
    const total_unsolved = attrs + val_total;

    // Self-referential length: total = blip_size(total) + total_unsolved
    var total_len: u64 = 0;
    {
        var L_bytes: usize = 1;
        while (L_bytes <= 9) : (L_bytes += 1) {
            const candidate = total_unsolved + L_bytes;
            if (blip.encodedSize(candidate) == L_bytes) {
                total_len = candidate;
                break;
            }
        }
        if (total_len == 0) return error.InvalidLength;
    }

    var out = try allocator.alloc(u8, @intCast(total_len));
    errdefer allocator.free(out);

    var pos: usize = 0;
    // BLIP(total_length)
    pos += try blip.encode(total_len, out[pos..]);
    // TYPE sentinel + BLIP(9)
    out[pos] = 0x81;
    out[pos + 1] = @intFromEnum(ct.AttributeSigil.type_attr);
    pos += 2;
    pos += try blip.encode(@intFromEnum(ct.ContainerTypeId.segment), out[pos..]);
    // CSUM attr (if any) — BEFORE SEG because 0x12 < 0x14
    if (csum_id) |cid| {
        out[pos] = 0x81;
        out[pos + 1] = @intFromEnum(ct.AttributeSigil.csum);
        pos += 2;
        pos += try blip.encode(@intFromEnum(cid), out[pos..]);
    }
    // SEG sentinel + I + M + N
    out[pos] = 0x81;
    out[pos + 1] = @intFromEnum(ct.AttributeSigil.seg);
    pos += 2;
    pos += try blip.encode(stream_id, out[pos..]);
    pos += try blip.encode(seg_index, out[pos..]);
    if (total) |n| {
        pos += try blip.encode(n, out[pos..]);
    } else {
        pos += try blip.encodeScalar(.nil, out[pos..]);
    }
    // VAL sentinel
    out[pos] = 0x81;
    out[pos + 1] = @intFromEnum(ct.AttributeSigil.val);
    pos += 2;
    // VAL payload + optional checksum
    @memcpy(out[pos..][0..val.len], val);
    pos += val.len;
    if (csum_id) |cid| {
        const full = checksum.compute(cid, val);
        const cbytes = checksum.slice(cid, &full);
        @memcpy(out[pos..][0..cbytes.len], cbytes);
        pos += cbytes.len;
    }

    std.debug.assert(pos == total_len);
    return out;
}

/// Reassemble a list of SEGMENT-container byte slices belonging to stream
/// `expected_stream_id` into the original concatenated payload.  Caller owns
/// the returned slice.  See BLIP_WIRE_SPEC §Segmentation for the rules.
pub fn reassemble(
    allocator: Allocator,
    segments: []const []const u8,
    expected_stream_id: u64,
) SegError![]u8 {
    // Step 1+2: parse + filter by I, drop CSUM-failing copies
    var survivors: std.ArrayListUnmanaged(SegInfo) = .empty;
    defer survivors.deinit(allocator);

    for (segments) |seg_buf| {
        const info = parseSegment(seg_buf) catch continue;
        if (info.stream_id != expected_stream_id) continue;
        if (info.csum_id) |cid| {
            const expected = info.csum_bytes;
            const computed_full = checksum.compute(cid, info.val);
            const computed = checksum.slice(cid, &computed_full);
            if (!std.mem.eql(u8, expected, computed)) continue; // drop bad copy
        }
        try survivors.append(allocator, info);
    }

    if (survivors.items.len == 0) return error.MissingSegments;

    // Step 3: N must be consistent
    const N0 = survivors.items[0].total;
    for (survivors.items) |s| {
        const eq = (s.total == null and N0 == null) or
            (s.total != null and N0 != null and s.total.? == N0.?);
        if (!eq) return error.InconsistentTotal;
    }

    // Step 4: coalesce duplicate-M
    // O(n^2) is fine here — segment counts are small.
    std.mem.sort(SegInfo, survivors.items, {}, struct {
        fn lt(_: void, a: SegInfo, b: SegInfo) bool {
            return a.seg_index < b.seg_index;
        }
    }.lt);

    var deduped: std.ArrayListUnmanaged(SegInfo) = .empty;
    defer deduped.deinit(allocator);
    var i: usize = 0;
    while (i < survivors.items.len) {
        const cur = survivors.items[i];
        var j = i + 1;
        // group all with the same M
        while (j < survivors.items.len and survivors.items[j].seg_index == cur.seg_index) : (j += 1) {
            if (!std.mem.eql(u8, survivors.items[j].val, cur.val)) {
                return error.DuplicateSegmentValueMismatch;
            }
        }
        try deduped.append(allocator, cur);
        i = j;
    }

    // Step 5: numeric N → require complete + dense range [1..N] (1-based)
    if (N0) |n| {
        if (deduped.items.len != n) return error.MissingSegments;
        for (deduped.items, 0..) |s, idx| {
            if (s.seg_index != idx + 1) return error.SequenceGap;
        }
    }
    // streaming (N=null): just sort and concatenate, missing detection N/A

    // Step 6: concat
    var total_size: usize = 0;
    for (deduped.items) |s| total_size += s.val.len;
    var out = try allocator.alloc(u8, total_size);
    errdefer allocator.free(out);
    var off: usize = 0;
    for (deduped.items) |s| {
        @memcpy(out[off..][0..s.val.len], s.val);
        off += s.val.len;
    }
    return out;
}

/// Split `raw` bytes into N SEGMENT containers, each carrying at most
/// `max_payload` bytes of VAL.  Caller owns the returned slice of slices and
/// each inner slice (free both individually).
/// `stream_id` is typically 0 for single-stream archives.
/// Empty input still produces 1 SEGMENT (with empty VAL, N=1) so the
/// reassembly invariant — at least one segment per archive — holds.
pub fn chunkBytes(
    allocator: Allocator,
    raw: []const u8,
    max_payload: usize,
    stream_id: u64,
    csum_id: ?ct.ChecksumId,
) SegError![][]u8 {
    if (max_payload == 0) return error.InvalidSegment;
    const N: usize = if (raw.len == 0) 1 else (raw.len + max_payload - 1) / max_payload;
    const segments = try allocator.alloc([]u8, N);
    var emitted: usize = 0;
    errdefer {
        for (segments[0..emitted]) |s| allocator.free(s);
        allocator.free(segments);
    }
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const start = i * max_payload;
        const end = @min(start + max_payload, raw.len);
        const slice = if (raw.len == 0) raw[0..0] else raw[start..end];
        segments[i] = try serializeSegment(allocator, stream_id, i + 1, N, slice, csum_id);
        emitted += 1;
    }
    return segments;
}

/// Free a slice-of-slices returned by `chunkBytes`.
pub fn freeSegmentList(allocator: Allocator, segments: [][]u8) void {
    for (segments) |s| allocator.free(s);
    allocator.free(segments);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "serializeSegment + parseSegment roundtrip: minimal segment, N=1" {
    const val = "hello world";
    const buf = try serializeSegment(testing.allocator, 0, 1, 1, val, null);
    defer testing.allocator.free(buf);
    const info = try parseSegment(buf);
    try testing.expectEqual(@as(u64, 0), info.stream_id);
    try testing.expectEqual(@as(u64, 1), info.seg_index);
    try testing.expectEqual(@as(?u64, 1), info.total);
    try testing.expectEqualSlices(u8, val, info.val);
    try testing.expect(info.csum_id == null);
}

test "serializeSegment + parseSegment roundtrip: streaming N=NIL" {
    const val = "fragment";
    const buf = try serializeSegment(testing.allocator, 7, 3, null, val, null);
    defer testing.allocator.free(buf);
    const info = try parseSegment(buf);
    try testing.expectEqual(@as(u64, 7), info.stream_id);
    try testing.expectEqual(@as(u64, 3), info.seg_index);
    try testing.expectEqual(@as(?u64, null), info.total);
    try testing.expectEqualSlices(u8, val, info.val);
}

test "serializeSegment + parseSegment roundtrip: with xxhash64 CSUM" {
    const val = "checksummed payload";
    const buf = try serializeSegment(testing.allocator, 0, 1, 1, val, .xxhash64);
    defer testing.allocator.free(buf);
    const info = try parseSegment(buf);
    try testing.expectEqual(@as(u64, 0), info.stream_id);
    try testing.expectEqualSlices(u8, val, info.val);
    try testing.expect(info.csum_id == .xxhash64);
    try testing.expectEqual(@as(usize, 8), info.csum_bytes.len);
    // Verify checksum matches
    const computed_full = checksum.compute(.xxhash64, val);
    const computed = checksum.slice(.xxhash64, &computed_full);
    try testing.expectEqualSlices(u8, computed, info.csum_bytes);
}

test "reassemble: single segment, N=1" {
    const val = "the only piece";
    const buf = try serializeSegment(testing.allocator, 0, 1, 1, val, null);
    defer testing.allocator.free(buf);
    const segs = [_][]const u8{buf};
    const out = try reassemble(testing.allocator, &segs, 0);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, val, out);
}

test "reassemble: two segments in order, N=2" {
    const a = try serializeSegment(testing.allocator, 0, 1, 2, "AAA", null);
    defer testing.allocator.free(a);
    const b = try serializeSegment(testing.allocator, 0, 2, 2, "BBB", null);
    defer testing.allocator.free(b);
    const segs = [_][]const u8{ a, b };
    const out = try reassemble(testing.allocator, &segs, 0);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, "AAABBB", out);
}

test "reassemble: out-of-order segments are sorted by M" {
    const a = try serializeSegment(testing.allocator, 0, 1, 3, "AAA", null);
    defer testing.allocator.free(a);
    const b = try serializeSegment(testing.allocator, 0, 2, 3, "BBB", null);
    defer testing.allocator.free(b);
    const c = try serializeSegment(testing.allocator, 0, 3, 3, "CCC", null);
    defer testing.allocator.free(c);
    const segs = [_][]const u8{ c, a, b }; // out of order
    const out = try reassemble(testing.allocator, &segs, 0);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, "AAABBBCCC", out);
}

test "reassemble: missing segment with numeric N -> error" {
    const a = try serializeSegment(testing.allocator, 0, 1, 3, "AAA", null);
    defer testing.allocator.free(a);
    const c = try serializeSegment(testing.allocator, 0, 3, 3, "CCC", null);
    defer testing.allocator.free(c);
    const segs = [_][]const u8{ a, c };
    try testing.expectError(SegError.MissingSegments, reassemble(testing.allocator, &segs, 0));
}

test "reassemble: inconsistent N -> error" {
    const a = try serializeSegment(testing.allocator, 0, 1, 2, "AAA", null);
    defer testing.allocator.free(a);
    const b = try serializeSegment(testing.allocator, 0, 2, 3, "BBB", null);
    defer testing.allocator.free(b);
    const segs = [_][]const u8{ a, b };
    try testing.expectError(SegError.InconsistentTotal, reassemble(testing.allocator, &segs, 0));
}

test "reassemble: streaming (N=NIL) accepts whatever is present" {
    const a = try serializeSegment(testing.allocator, 0, 1, null, "AAA", null);
    defer testing.allocator.free(a);
    const b = try serializeSegment(testing.allocator, 0, 2, null, "BBB", null);
    defer testing.allocator.free(b);
    // Note: missing M=3 is *undetectable* in streaming mode, by design.
    const segs = [_][]const u8{ a, b };
    const out = try reassemble(testing.allocator, &segs, 0);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, "AAABBB", out);
}

test "reassemble: duplicate-M with matching VAL coalesces" {
    const a = try serializeSegment(testing.allocator, 0, 1, 2, "AAA", null);
    defer testing.allocator.free(a);
    const a_dup = try serializeSegment(testing.allocator, 0, 1, 2, "AAA", null);
    defer testing.allocator.free(a_dup);
    const b = try serializeSegment(testing.allocator, 0, 2, 2, "BBB", null);
    defer testing.allocator.free(b);
    const segs = [_][]const u8{ a, a_dup, b };
    const out = try reassemble(testing.allocator, &segs, 0);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, "AAABBB", out);
}

test "reassemble: duplicate-M with mismatching VAL -> error" {
    const a = try serializeSegment(testing.allocator, 0, 1, 2, "AAA", null);
    defer testing.allocator.free(a);
    const a_evil = try serializeSegment(testing.allocator, 0, 1, 2, "XXX", null);
    defer testing.allocator.free(a_evil);
    const b = try serializeSegment(testing.allocator, 0, 2, 2, "BBB", null);
    defer testing.allocator.free(b);
    const segs = [_][]const u8{ a, a_evil, b };
    try testing.expectError(
        SegError.DuplicateSegmentValueMismatch,
        reassemble(testing.allocator, &segs, 0),
    );
}

test "reassemble: filters out segments belonging to other streams" {
    const a = try serializeSegment(testing.allocator, 0, 1, 2, "AAA", null);
    defer testing.allocator.free(a);
    const b = try serializeSegment(testing.allocator, 0, 2, 2, "BBB", null);
    defer testing.allocator.free(b);
    const noise1 = try serializeSegment(testing.allocator, 99, 1, 1, "WRONG", null);
    defer testing.allocator.free(noise1);
    const segs = [_][]const u8{ a, noise1, b };
    const out = try reassemble(testing.allocator, &segs, 0);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, "AAABBB", out);
}

test "reassemble: corrupt CSUM copy is silently dropped, valid copy wins" {
    const val_a = "AAA";
    const val_b = "BBB";
    const a_good = try serializeSegment(testing.allocator, 0, 1, 2, val_a, .xxhash64);
    defer testing.allocator.free(a_good);
    // tamper a_good's payload: flip a byte in the VAL area while leaving CSUM untouched
    const a_corrupt = try testing.allocator.dupe(u8, a_good);
    defer testing.allocator.free(a_corrupt);
    // tamper VAL byte (the first 'A')
    const info_for_offset = try parseSegment(a_corrupt);
    const off = @intFromPtr(info_for_offset.val.ptr) - @intFromPtr(a_corrupt.ptr);
    a_corrupt[off] ^= 0xFF;

    const b = try serializeSegment(testing.allocator, 0, 2, 2, val_b, .xxhash64);
    defer testing.allocator.free(b);

    const segs = [_][]const u8{ a_corrupt, a_good, b };
    const out = try reassemble(testing.allocator, &segs, 0);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, "AAABBB", out);
}

test "reassemble: empty segment list -> MissingSegments" {
    const segs = [_][]const u8{};
    try testing.expectError(SegError.MissingSegments, reassemble(testing.allocator, &segs, 0));
}

test "reassemble: all segments belong to wrong stream -> MissingSegments" {
    const a = try serializeSegment(testing.allocator, 99, 1, 1, "WRONG", null);
    defer testing.allocator.free(a);
    const segs = [_][]const u8{a};
    try testing.expectError(SegError.MissingSegments, reassemble(testing.allocator, &segs, 0));
}

test "parseSegment: rejects non-SEGMENT containers with NotASegment" {
    // Build a tiny UTF8 container instead — should fail parseSegment.
    var buf: [16]u8 = undefined;
    // BLIP(total=8) TYPE_sentinel BLIP(3=utf8) VAL_sentinel "abc"
    var pos: usize = 0;
    pos += blip.encode(8, buf[0..]) catch unreachable;
    buf[pos] = 0x81;
    buf[pos + 1] = 0x01;
    pos += 2;
    pos += blip.encode(3, buf[pos..]) catch unreachable; // utf8 type id
    buf[pos] = 0x81;
    buf[pos + 1] = 0x7F;
    pos += 2;
    @memcpy(buf[pos..][0..3], "abc");
    pos += 3;
    try testing.expectError(SegError.NotASegment, parseSegment(buf[0..pos]));
}

test "chunkBytes: 100 bytes max=30 -> 4 segments" {
    var raw: [100]u8 = undefined;
    for (raw[0..], 0..) |*b, i| b.* = @intCast(i);
    const segs = try chunkBytes(testing.allocator, &raw, 30, 0, null);
    defer freeSegmentList(testing.allocator, segs);
    try testing.expectEqual(@as(usize, 4), segs.len);
    // Verify each segment carries the expected slice
    const sizes = [_]usize{ 30, 30, 30, 10 };
    for (segs, 0..) |seg, i| {
        const info = try parseSegment(seg);
        try testing.expectEqual(@as(u64, 0), info.stream_id);
        try testing.expectEqual(@as(u64, i + 1), info.seg_index);
        try testing.expectEqual(@as(?u64, 4), info.total);
        try testing.expectEqual(sizes[i], info.val.len);
    }
}

test "chunkBytes + reassemble = original bytes" {
    var raw: [1024]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(0xCAFEBABE);
    rng.fill(&raw);
    const segs = try chunkBytes(testing.allocator, &raw, 100, 0, .xxhash64);
    defer freeSegmentList(testing.allocator, segs);
    try testing.expectEqual(@as(usize, 11), segs.len); // ceil(1024/100)

    // Cast [][]u8 to []const []const u8 for reassemble's signature.
    var const_segs = try testing.allocator.alloc([]const u8, segs.len);
    defer testing.allocator.free(const_segs);
    for (segs, 0..) |s, i| const_segs[i] = s;

    const out = try reassemble(testing.allocator, const_segs, 0);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &raw, out);
}

test "chunkBytes: empty input produces 1 empty segment with N=1" {
    const segs = try chunkBytes(testing.allocator, &.{}, 100, 0, null);
    defer freeSegmentList(testing.allocator, segs);
    try testing.expectEqual(@as(usize, 1), segs.len);
    const info = try parseSegment(segs[0]);
    try testing.expectEqual(@as(?u64, 1), info.total);
    try testing.expectEqual(@as(usize, 0), info.val.len);
}

test "chunkBytes: max_payload = 0 -> InvalidSegment" {
    try testing.expectError(SegError.InvalidSegment, chunkBytes(testing.allocator, "x", 0, 0, null));
}

test "chunkBytes: exact multiple does not produce empty trailing segment" {
    var raw: [60]u8 = undefined;
    @memset(&raw, 0xAB);
    const segs = try chunkBytes(testing.allocator, &raw, 30, 0, null);
    defer freeSegmentList(testing.allocator, segs);
    try testing.expectEqual(@as(usize, 2), segs.len);
}
