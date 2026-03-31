const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TarError = error{
    InvalidTar,
    UnsupportedTar,
    CorruptedData,
};

/// A single entry parsed from a tar archive.
pub const TarEntry = struct {
    /// Full 512-byte header block (for faithful reconstruction).
    header: [512]u8,
    /// File path from header (name + optional prefix).
    path: []const u8,
    /// File content (empty for directories).
    content: []const u8,
    /// Entry type: '0' or '\0' = file, '5' = directory, etc.
    typeflag: u8,
};

pub const ParsedTar = struct {
    entries: []TarEntry,
    /// Trailing bytes after all entries (padding/EOF blocks).
    trailer: []u8,
    allocator: Allocator,

    pub fn deinit(self: *ParsedTar) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.path);
            if (entry.content.len > 0) {
                self.allocator.free(entry.content);
            }
        }
        self.allocator.free(self.entries);
        if (self.trailer.len > 0) {
            self.allocator.free(self.trailer);
        }
    }
};

/// Check if buffer looks like a tar archive.
/// Checks for "ustar" magic at offset 257 (POSIX/GNU tar).
/// Also accepts archives where the first header has a valid checksum.
pub fn isTarMagic(buf: []const u8) bool {
    if (buf.len < 512) return false;
    // Check for "ustar" magic at offset 257
    if (buf.len >= 263 and
        buf[257] == 'u' and buf[258] == 's' and buf[259] == 't' and
        buf[260] == 'a' and buf[261] == 'r')
    {
        return true;
    }
    // Fallback: verify header checksum for pre-POSIX tar
    return verifyChecksum(buf[0..512]);
}

/// Read an octal number from a tar header field.
/// Handles both null-terminated and space-terminated octal strings.
/// Also handles GNU binary extensions (0x80 prefix).
fn readOctal(field: []const u8) u64 {
    // GNU binary extension: high bit set
    if (field.len > 0 and (field[0] & 0x80) != 0) {
        // Binary big-endian, skip first byte (marker)
        var val: u64 = 0;
        for (field[1..]) |b| {
            val = (val << 8) | @as(u64, b);
        }
        return val;
    }

    var val: u64 = 0;
    for (field) |c| {
        if (c == 0 or c == ' ') break;
        if (c < '0' or c > '7') return 0;
        val = val * 8 + @as(u64, c - '0');
    }
    return val;
}

/// Verify tar header checksum (sum of all bytes, with chksum field as spaces).
fn verifyChecksum(header: *const [512]u8) bool {
    // All-zero block is a valid EOF marker, not a valid header
    var all_zero = true;
    for (header) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) return false;

    const stored = readOctal(header[148..156]);
    var computed: u64 = 0;
    for (0..512) |i| {
        if (i >= 148 and i < 156) {
            computed += ' '; // chksum field treated as spaces
        } else {
            computed += @as(u64, header[i]);
        }
    }
    return computed == stored;
}

/// Extract the path from a tar header (handles prefix for POSIX/ustar).
fn extractPath(allocator: Allocator, header: *const [512]u8) ![]u8 {
    // name field: bytes 0..100
    var name_len: usize = 0;
    while (name_len < 100 and header[name_len] != 0) : (name_len += 1) {}

    // prefix field (ustar): bytes 345..500
    var prefix_len: usize = 0;
    if (header[257] == 'u' and header[258] == 's' and header[259] == 't') {
        while (prefix_len < 155 and header[345 + prefix_len] != 0) : (prefix_len += 1) {}
    }

    if (prefix_len > 0) {
        const path = try allocator.alloc(u8, prefix_len + 1 + name_len);
        @memcpy(path[0..prefix_len], header[345..][0..prefix_len]);
        path[prefix_len] = '/';
        @memcpy(path[prefix_len + 1 ..][0..name_len], header[0..name_len]);
        return path;
    } else {
        const path = try allocator.alloc(u8, name_len);
        @memcpy(path, header[0..name_len]);
        return path;
    }
}

/// Parse a tar archive into individual entries.
pub fn parseTar(allocator: Allocator, data: []const u8) (TarError || Allocator.Error)!ParsedTar {
    if (data.len < 512) return TarError.InvalidTar;
    if (!isTarMagic(data)) return TarError.InvalidTar;

    var entries = std.ArrayListUnmanaged(TarEntry){};
    defer entries.deinit(allocator);

    var offset: usize = 0;
    while (offset + 512 <= data.len) {
        const header: *const [512]u8 = @ptrCast(data[offset..][0..512]);

        // Check for EOF (two consecutive zero blocks)
        var all_zero = true;
        for (header) |b| {
            if (b != 0) {
                all_zero = false;
                break;
            }
        }
        if (all_zero) break;

        // Verify checksum
        if (!verifyChecksum(header)) {
            break; // Treat as end of archive
        }

        const size = readOctal(header[124..136]);
        const typeflag = header[156];

        offset += 512; // Past header

        // Extract path
        const path = extractPath(allocator, header) catch return TarError.CorruptedData;

        // Read content
        const content_end = offset + @as(usize, size);
        if (content_end > data.len) {
            allocator.free(path);
            return TarError.CorruptedData;
        }

        var content: []u8 = &.{};
        if (size > 0) {
            content = try allocator.alloc(u8, @intCast(size));
            @memcpy(content, data[offset..content_end]);
        }

        var entry_header: [512]u8 = undefined;
        @memcpy(&entry_header, header);

        try entries.append(allocator, TarEntry{
            .header = entry_header,
            .path = path,
            .content = content,
            .typeflag = typeflag,
        });

        // Advance past content (padded to 512-byte boundary)
        offset = (content_end + 511) & ~@as(usize, 511);
    }

    if (entries.items.len == 0) return TarError.InvalidTar;

    // Capture trailer (EOF blocks + any trailing padding)
    const trailer_len = if (offset < data.len) data.len - offset else 0;
    var trailer: []u8 = &.{};
    if (trailer_len > 0) {
        trailer = try allocator.alloc(u8, trailer_len);
        @memcpy(trailer, data[offset..]);
    }

    return ParsedTar{
        .entries = try entries.toOwnedSlice(allocator),
        .trailer = trailer,
        .allocator = allocator,
    };
}

/// Reconstruct a tar archive from entries + trailer.
pub fn encodeTar(allocator: Allocator, entries: []const TarEntry, trailer: []const u8) Allocator.Error![]u8 {
    // Calculate total size
    var total: usize = 0;
    for (entries) |entry| {
        total += 512; // header
        total += (entry.content.len + 511) & ~@as(usize, 511); // padded content
    }
    total += if (trailer.len > 0) trailer.len else 1024; // EOF blocks

    const output = try allocator.alloc(u8, total);
    @memset(output, 0);

    var offset: usize = 0;
    for (entries) |entry| {
        @memcpy(output[offset..][0..512], &entry.header);
        offset += 512;
        if (entry.content.len > 0) {
            @memcpy(output[offset..][0..entry.content.len], entry.content);
            offset += (entry.content.len + 511) & ~@as(usize, 511);
        }
    }

    if (trailer.len > 0) {
        @memcpy(output[offset..][0..trailer.len], trailer);
    }
    // else: the zeros we memset cover the EOF blocks

    return output;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build a minimal valid tar archive in memory for testing.
fn makeTestTar(allocator: Allocator) ![]u8 {
    // One file: "hello.txt" with content "Hello, tar!\n"
    const content = "Hello, tar!\n";
    const content_len = content.len;

    // Total: header(512) + content padded to 512 + 2 EOF blocks(1024)
    const total = 512 + 512 + 1024;
    const buf = try allocator.alloc(u8, total);
    @memset(buf, 0);

    // File name
    @memcpy(buf[0..9], "hello.txt");
    // Mode: 0644
    @memcpy(buf[100..107], "0000644");
    // UID/GID: 0
    @memcpy(buf[108..115], "0000000");
    @memcpy(buf[116..123], "0000000");
    // Size in octal (12 = 014)
    @memcpy(buf[124..135], "00000000014");
    // Mtime
    @memcpy(buf[136..147], "14740254751");
    // Typeflag: regular file
    buf[156] = '0';
    // Magic "ustar\0"
    @memcpy(buf[257..263], "ustar\x00");
    // Version "00"
    @memcpy(buf[263..265], "00");

    // Compute checksum
    var checksum: u64 = 0;
    // First set checksum field to spaces
    @memset(buf[148..156], ' ');
    for (buf[0..512]) |b| {
        checksum += @as(u64, b);
    }
    // Write checksum as 6-digit octal + null + space
    var chk_buf: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&chk_buf, "{o:0>6}\x00 ", .{checksum}) catch unreachable;
    @memcpy(buf[148..156], &chk_buf);

    // Content
    @memcpy(buf[512..][0..content_len], content);

    return buf;
}

test "tar magic detection" {
    const tar_data = try makeTestTar(testing.allocator);
    defer testing.allocator.free(tar_data);
    try testing.expect(isTarMagic(tar_data));
}

test "tar magic rejects non-tar" {
    try testing.expect(!isTarMagic(&[_]u8{ 'P', 'K', 3, 4, 0, 0 }));
    try testing.expect(!isTarMagic(&[_]u8{}));
    var zeros: [512]u8 = undefined;
    @memset(&zeros, 0);
    try testing.expect(!isTarMagic(&zeros));
}

test "tar parse and roundtrip" {
    const tar_data = try makeTestTar(testing.allocator);
    defer testing.allocator.free(tar_data);

    var parsed = try parseTar(testing.allocator, tar_data);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.entries.len);
    try testing.expectEqualStrings("hello.txt", parsed.entries[0].path);
    try testing.expectEqualStrings("Hello, tar!\n", parsed.entries[0].content);
    try testing.expectEqual(@as(u8, '0'), parsed.entries[0].typeflag);

    // Roundtrip
    const re_encoded = try encodeTar(testing.allocator, parsed.entries, parsed.trailer);
    defer testing.allocator.free(re_encoded);

    try testing.expectEqualSlices(u8, tar_data, re_encoded);
}

test "tar parse rejects too small" {
    const result = parseTar(testing.allocator, &[_]u8{ 0, 0, 0 });
    try testing.expectError(TarError.InvalidTar, result);
}

test "tar octal reader" {
    try testing.expectEqual(@as(u64, 0o644), readOctal("0000644"));
    try testing.expectEqual(@as(u64, 12), readOctal("00000000014"));
    try testing.expectEqual(@as(u64, 0), readOctal("\x00\x00\x00"));
    try testing.expectEqual(@as(u64, 0o755), readOctal("0000755\x00"));
}
