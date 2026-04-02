//! NIfTI-1 parser for neuroimaging container expansion.
//! NIfTI (.nii) files have a 348-byte header + raw voxel data.
//! Used in fMRI, structural MRI, and other neuroimaging modalities.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const NiftiError = error{
    InvalidNifti,
    UnsupportedNifti,
    CorruptedData,
};

pub const NiftiInfo = struct {
    /// Image dimensions: [0]=ndim, [1..]=dim sizes
    dim: [8]u16,
    /// Datatype code (2=uint8, 4=int16, 8=int32, 16=float32, 64=float64, 512=uint16)
    datatype: u16,
    /// Bits per voxel
    bitpix: u16,
    /// Byte offset to voxel data (typically 352 for .nii)
    vox_offset: f32,
};

pub const ParsedNifti = struct {
    info: NiftiInfo,
    /// Raw voxel data.
    voxels: []u8,
    /// Compact metadata: non-voxel bytes.
    /// Format: [u32_le file_size][u32_le vox_offset][u32_le vox_size]
    ///         [header_bytes][post_voxel_bytes]
    meta: []u8,
    allocator: Allocator,

    pub fn deinit(self: *ParsedNifti) void {
        self.allocator.free(self.voxels);
        self.allocator.free(self.meta);
    }
};

/// NIfTI-1 magic: "n+1\0" at offset 344 (single-file .nii) or "ni1\0" (header-only .hdr)
pub fn isNiftiMagic(buf: []const u8) bool {
    if (buf.len < 348) return false;
    // Check sizeof_hdr == 348 (little-endian)
    const hdr_size = readU32LE(buf[0..4]);
    if (hdr_size != 348) {
        // Try big-endian
        const hdr_size_be = readU32BE(buf[0..4]);
        if (hdr_size_be != 348) return false;
    }
    // Check magic at offset 344
    return (buf[344] == 'n' and buf[345] == '+' and buf[346] == '1' and buf[347] == 0) or
        (buf[344] == 'n' and buf[345] == 'i' and buf[346] == '1' and buf[347] == 0);
}

fn readU16LE(buf: []const u8) u16 {
    return std.mem.readInt(u16, buf[0..2], .little);
}

fn readU32LE(buf: []const u8) u32 {
    return std.mem.readInt(u32, buf[0..4], .little);
}

fn readU32BE(buf: []const u8) u32 {
    return std.mem.readInt(u32, buf[0..4], .big);
}

fn readF32LE(buf: []const u8) f32 {
    return @bitCast(std.mem.readInt(u32, buf[0..4], .little));
}
/// Parse a NIfTI-1 single-file (.nii).
/// Only supports 8-bit and 16-bit integer datatypes for JXL transcoding.
pub fn parseNifti(allocator: Allocator, data: []const u8) (NiftiError || Allocator.Error)!ParsedNifti {
    if (data.len < 352) return NiftiError.InvalidNifti;
    if (!isNiftiMagic(data)) return NiftiError.InvalidNifti;

    // Only handle single-file format ("n+1\0")
    if (data[344] != 'n' or data[345] != '+') return NiftiError.UnsupportedNifti;

    // Detect endianness from sizeof_hdr
    const is_le = readU32LE(data[0..4]) == 348;

    // Read dimensions
    var dim: [8]u16 = undefined;
    for (0..8) |i| {
        const off = 40 + i * 2;
        dim[i] = if (is_le) readU16LE(data[off..][0..2]) else @byteSwap(readU16LE(data[off..][0..2]));
    }

    const datatype = if (is_le) readU16LE(data[70..72]) else @byteSwap(readU16LE(data[70..72]));
    const bitpix = if (is_le) readU16LE(data[72..74]) else @byteSwap(readU16LE(data[72..74]));

    // Only handle 8-bit (uint8) and 16-bit (int16/uint16) for JXL
    if (bitpix != 8 and bitpix != 16) return NiftiError.UnsupportedNifti;

    const vox_offset_f = if (is_le) readF32LE(data[108..112]) else @as(f32, @bitCast(@byteSwap(readU32LE(data[108..112]))));
    const vox_offset: usize = @intFromFloat(vox_offset_f);

    if (vox_offset >= data.len) return NiftiError.CorruptedData;

    // Calculate voxel data size from dimensions
    const ndim = dim[0];
    if (ndim < 2) return NiftiError.UnsupportedNifti;

    var vox_count: usize = 1;
    for (1..@as(usize, ndim) + 1) |i| {
        if (dim[i] == 0) break;
        vox_count *= @as(usize, dim[i]);
    }

    const bytes_per_voxel: usize = @as(usize, bitpix) / 8;
    const vox_size = vox_count * bytes_per_voxel;

    if (vox_offset + vox_size > data.len) return NiftiError.CorruptedData;

    // Copy voxel data
    const voxels = try allocator.alloc(u8, vox_size);
    @memcpy(voxels, data[vox_offset..][0..vox_size]);

    // Build compact metadata (same pattern as FITS/DICOM)
    const post_vox_start = vox_offset + vox_size;
    const post_vox_len = if (post_vox_start < data.len) data.len - post_vox_start else 0;
    const meta_prefix: usize = 12;
    const meta_len = meta_prefix + vox_offset + post_vox_len;
    const meta = try allocator.alloc(u8, meta_len);

    std.mem.writeInt(u32, meta[0..4], @intCast(data.len), .little);
    std.mem.writeInt(u32, meta[4..8], @intCast(vox_offset), .little);
    std.mem.writeInt(u32, meta[8..12], @intCast(vox_size), .little);
    @memcpy(meta[meta_prefix..][0..vox_offset], data[0..vox_offset]);
    if (post_vox_len > 0) @memcpy(meta[meta_prefix + vox_offset ..], data[post_vox_start..]);

    return ParsedNifti{
        .info = NiftiInfo{
            .dim = dim,
            .datatype = datatype,
            .bitpix = bitpix,
            .vox_offset = vox_offset_f,
        },
        .voxels = voxels,
        .meta = meta,
        .allocator = allocator,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeTestNifti(allocator: Allocator, width: u16, height: u16, slices: u16, bitpix: u16) ![]u8 {
    const bytes_per_voxel: usize = @as(usize, bitpix) / 8;
    const vox_count = @as(usize, width) * @as(usize, height) * @as(usize, slices);
    const vox_size = vox_count * bytes_per_voxel;
    const vox_offset: usize = 352; // standard for .nii
    const total = vox_offset + vox_size;

    const buf = try allocator.alloc(u8, total);
    @memset(buf, 0);

    // sizeof_hdr = 348 (LE)
    std.mem.writeInt(u32, buf[0..4], 348, .little);

    // dim: ndim=3, dim[1]=width, dim[2]=height, dim[3]=slices
    std.mem.writeInt(u16, buf[40..42], 3, .little); // ndim
    std.mem.writeInt(u16, buf[42..44], width, .little);
    std.mem.writeInt(u16, buf[44..46], height, .little);
    std.mem.writeInt(u16, buf[46..48], slices, .little);

    // datatype + bitpix
    const datatype: u16 = if (bitpix == 8) 2 else 4; // DT_UINT8 or DT_INT16
    std.mem.writeInt(u16, buf[70..72], datatype, .little);
    std.mem.writeInt(u16, buf[72..74], bitpix, .little);

    // vox_offset = 352.0
    const voff: f32 = 352.0;
    std.mem.writeInt(u32, buf[108..112], @bitCast(voff), .little);

    // Magic: "n+1\0"
    buf[344] = 'n';
    buf[345] = '+';
    buf[346] = '1';
    buf[347] = 0;

    // Fill voxel data with pattern
    const voxels = buf[vox_offset..][0..vox_size];
    for (0..vox_count) |i| {
        if (bitpix == 8) {
            voxels[i] = @truncate((i * 17) & 0xFF);
        } else {
            const val: u16 = @truncate((i * 137) & 0xFFFF);
            voxels[i * 2] = @truncate(val);
            voxels[i * 2 + 1] = @truncate(val >> 8);
        }
    }

    return buf;
}

test "NIfTI magic detection" {
    const nii = try makeTestNifti(testing.allocator, 8, 8, 4, 8);
    defer testing.allocator.free(nii);
    try testing.expect(isNiftiMagic(nii));
}

test "NIfTI magic rejects non-NIfTI" {
    try testing.expect(!isNiftiMagic(&[_]u8{ 'B', 'M', 0, 0 }));
    var zeros: [400]u8 = undefined;
    @memset(&zeros, 0);
    try testing.expect(!isNiftiMagic(&zeros));
}

test "NIfTI parse 8-bit 3D" {
    const nii = try makeTestNifti(testing.allocator, 16, 12, 4, 8);
    defer testing.allocator.free(nii);

    var parsed = try parseNifti(testing.allocator, nii);
    defer parsed.deinit();

    try testing.expectEqual(@as(u16, 3), parsed.info.dim[0]);
    try testing.expectEqual(@as(u16, 16), parsed.info.dim[1]);
    try testing.expectEqual(@as(u16, 12), parsed.info.dim[2]);
    try testing.expectEqual(@as(u16, 4), parsed.info.dim[3]);
    try testing.expectEqual(@as(u16, 8), parsed.info.bitpix);
    try testing.expectEqual(@as(usize, 16 * 12 * 4), parsed.voxels.len);
}

test "NIfTI parse 16-bit 3D" {
    const nii = try makeTestNifti(testing.allocator, 8, 8, 2, 16);
    defer testing.allocator.free(nii);

    var parsed = try parseNifti(testing.allocator, nii);
    defer parsed.deinit();

    try testing.expectEqual(@as(u16, 16), parsed.info.bitpix);
    try testing.expectEqual(@as(usize, 8 * 8 * 2 * 2), parsed.voxels.len);
}

test "NIfTI metadata reconstruction info" {
    const nii = try makeTestNifti(testing.allocator, 8, 8, 2, 8);
    defer testing.allocator.free(nii);

    var parsed = try parseNifti(testing.allocator, nii);
    defer parsed.deinit();

    const file_size = std.mem.readInt(u32, parsed.meta[0..4], .little);
    try testing.expectEqual(@as(u32, @intCast(nii.len)), file_size);
}
