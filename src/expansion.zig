//! Container expansion and collapse — the core logic for decomposing file
//! formats into more compressible representations and reconstructing them.
//!
//! This module is the single entry point for all container format handling.
//! The C layer (blar_common.h) calls blip_expand_file() and blip_collapse_container()
//! through the FFI without implementing any format-specific logic itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

// Format modules
const bmp_mod = @import("bmp.zig");
const tga_mod = @import("tga.zig");
const tiff_mod = @import("tiff.zig");
const gif_mod = @import("gif.zig");
const png_mod = @import("png.zig");
const tar_mod = @import("tar.zig");
const wav_mod = @import("wav.zig");
const aiff_mod = @import("aiff.zig");
const fits_mod = @import("fits.zig");
const nifti_mod = @import("nifti.zig");
const dicom_mod = @import("dicom.zig");
const flac_mod = @import("flac.zig");
const jxl_mod = @import("jxl.zig");
const pdf_mod = @import("pdf.zig");
const zip_mod = @import("zip.zig");

/// A single entry produced by container expansion.
pub const ExpandedEntry = struct {
    /// Path suffix relative to the container (e.g. "__meta__", "__pixels__.jxl").
    path_suffix: []const u8,
    /// Content bytes (owned by the allocator).
    content: []u8,
    /// True if this entry is a directory.
    is_dir: bool,
    /// JXL source format tag (e.g. "png", "bmp"), or empty.
    jxl_source_format: []const u8,
    /// Gzip compression level (1-9) for gz containers, 0 otherwise.
    gz_level: u8,
    /// ZIP compression method (0=store, 8=deflate), 0xFFFF if N/A.
    zip_comp: u16 = 0xFFFF,
    /// PDF stream offset in the shell, maxInt if N/A.
    pdf_offset: u64 = std.math.maxInt(u64),
    /// PDF stream length in the shell, maxInt if N/A.
    pdf_length: u64 = std.math.maxInt(u64),
};

/// Result of expanding a file.
pub const ExpandResult = struct {
    /// Container type name (e.g. "bmp", "tiff", "wav").
    container_type: []const u8,
    /// Expanded child entries.
    entries: []ExpandedEntry,
    allocator: Allocator,

    pub fn deinit(self: *ExpandResult) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.path_suffix);
            if (entry.content.len > 0) self.allocator.free(entry.content);
        }
        self.allocator.free(self.entries);
    }
};

/// A child entry for container collapse (reconstruction).
pub const CollapseChild = struct {
    /// Inner path (relative to container, e.g. "__meta__", "__pixels__.jxl").
    inner_path: []const u8,
    /// Content bytes.
    content: []const u8,
    /// Optional metadata: PDF stream offset (UINT64_MAX if unused).
    pdf_offset: u64 = std.math.maxInt(u64),
    /// Optional metadata: PDF stream length (UINT64_MAX if unused).
    pdf_length: u64 = std.math.maxInt(u64),
    /// Optional metadata: ZIP compression method (0xFFFF if unused).
    zip_comp: u16 = 0xFFFF,
    /// Optional metadata: JXL source format tag.
    jxl_source: []const u8 = &.{},
    /// FlateDecode metadata for PDF image reconstruction.
    flate_predictor: u16 = 0,
    flate_columns: u32 = 0,
    flate_colors: u8 = 0,
    flate_bpc: u8 = 0,
};

// ── Format detection ─────────────────────────────────────────────────────

/// Detect which codec (if any) matches the given content by magic bytes.
/// Returns the codec name or null.
pub fn detectCodec(content: []const u8) ?[]const u8 {
    // Order matters: more specific formats first to avoid false positives.
    // JPEG must come before TIFF (some TIFFs contain JPEG, but JPEG has distinct FF D8 FF magic).
    if (content.len >= 3 and content[0] == 0xFF and content[1] == 0xD8 and content[2] == 0xFF) return "jpeg";
    if (pdf_mod.isPdfMagic(content)) return "pdf";
    if (png_mod.isPngMagic(content)) return "png";
    if (nifti_mod.isNiftiMagic(content)) return "nifti";
    if (dicom_mod.isDicomMagic(content)) return "dicom";
    if (fits_mod.isFitsMagic(content)) return "fits";
    if (aiff_mod.isAiffMagic(content)) return "aiff";
    if (wav_mod.isWavMagic(content)) return "wav";
    if (bmp_mod.isBmpMagic(content)) return "bmp";
    if (tga_mod.isTgaMagic(content)) return "tga";
    if (tiff_mod.isTiffMagic(content)) return "tiff";
    if (gif_mod.isGifMagic(content)) return "gif";
    if (tar_mod.isTarMagic(content)) return "tar";
    if (content.len >= 2 and content[0] == 0x1F and content[1] == 0x8B) return "gz";
    // ZIP detection: PK\x03\x04 magic
    if (content.len >= 4 and content[0] == 0x50 and content[1] == 0x4B and
        content[2] == 0x03 and content[3] == 0x04) return "zip";
    return null;
}

// ── Pixel-based expansion helpers ────────────────────────────────────────

/// Common pattern: parse format → pixels → JXL → [__meta__, __pixels__.jxl]
fn expandPixelFormat(
    allocator: Allocator,
    content: []const u8,
    codec_name: []const u8,
    min_size: usize,
) !?ExpandResult {
    if (content.len < min_size) return null;

    // Parse to pixels + metadata
    var pixels: []u8 = undefined;
    var meta: []u8 = undefined;
    var width: u32 = undefined;
    var height: u32 = undefined;
    var channels: u32 = undefined;
    var bps: u32 = undefined;

    if (std.mem.eql(u8, codec_name, "bmp")) {
        const parsed = bmp_mod.parseBmp(allocator, content) catch return null;
        pixels = parsed.pixels;
        width = parsed.header.width;
        height = parsed.header.abs_height;
        channels = parsed.header.channels;
        bps = 8;
        // Build meta: [u8 top_down][u16_le bpp][u32_le row_stride][header_bytes]
        const mp: usize = 1 + 2 + 4;
        meta = try allocator.alloc(u8, mp + parsed.header.header_bytes.len);
        meta[0] = if (parsed.header.top_down) 1 else 0;
        std.mem.writeInt(u16, meta[1..3], parsed.header.bits_per_pixel, .little);
        std.mem.writeInt(u32, meta[3..7], parsed.header.row_stride, .little);
        @memcpy(meta[mp..], parsed.header.header_bytes);
        allocator.free(parsed.header.header_bytes);
    } else if (std.mem.eql(u8, codec_name, "tga")) {
        const parsed = tga_mod.parseTga(allocator, content) catch return null;
        pixels = parsed.pixels;
        width = @as(u32, parsed.header.width);
        height = @as(u32, parsed.header.height);
        channels = @as(u32, parsed.header.channels);
        bps = 8;
        const mp: usize = 1 + 1 + 2 + 2 + 4;
        meta = try allocator.alloc(u8, mp + parsed.header.header_bytes.len + parsed.footer.len);
        meta[0] = if (parsed.header.top_down) 1 else 0;
        meta[1] = parsed.header.bits_per_pixel;
        std.mem.writeInt(u16, meta[2..4], parsed.header.width, .little);
        std.mem.writeInt(u16, meta[4..6], parsed.header.height, .little);
        std.mem.writeInt(u32, meta[6..10], @intCast(parsed.footer.len), .little);
        @memcpy(meta[mp..][0..parsed.header.header_bytes.len], parsed.header.header_bytes);
        if (parsed.footer.len > 0) @memcpy(meta[mp + parsed.header.header_bytes.len ..], parsed.footer);
        allocator.free(parsed.header.header_bytes);
        if (parsed.footer.len > 0) allocator.free(parsed.footer);
    } else if (std.mem.eql(u8, codec_name, "tiff")) {
        const parsed = tiff_mod.parseTiff(allocator, content) catch return null;
        pixels = parsed.pixels;
        width = parsed.info.width;
        height = parsed.info.height;
        channels = @as(u32, parsed.info.samples_per_pixel);
        bps = @as(u32, parsed.info.bits_per_sample);
        meta = parsed.meta;
    } else if (std.mem.eql(u8, codec_name, "png")) {
        const parsed = png_mod.parsePng(allocator, content) catch return null;
        pixels = parsed.pixels;
        width = parsed.info.width;
        height = parsed.info.height;
        channels = parsed.info.channels;
        bps = @as(u32, parsed.info.bit_depth);
        // Build meta: [u32_be pre_idat_len][pre_idat][post_idat]
        meta = try allocator.alloc(u8, 4 + parsed.pre_idat.len + parsed.post_idat.len);
        std.mem.writeInt(u32, meta[0..4], @intCast(parsed.pre_idat.len), .big);
        @memcpy(meta[4..][0..parsed.pre_idat.len], parsed.pre_idat);
        @memcpy(meta[4 + parsed.pre_idat.len ..], parsed.post_idat);
        allocator.free(parsed.pre_idat);
        allocator.free(parsed.post_idat);
    } else if (std.mem.eql(u8, codec_name, "gif")) {
        var parsed = gif_mod.parseGif(allocator, content) catch return null;
        if (parsed.is_animated) { parsed.deinit(); return null; }
        pixels = parsed.pixels;
        width = parsed.width;
        height = parsed.height;
        channels = 4; // RGBA
        bps = 8;
        meta = parsed.original; // Store full original for GIF (palette can't be reconstructed from pixels)
    } else if (std.mem.eql(u8, codec_name, "fits")) {
        const parsed = fits_mod.parseFits(allocator, content) catch return null;
        pixels = parsed.pixels;
        width = parsed.info.width;
        height = parsed.info.height;
        channels = parsed.info.channels;
        bps = @intCast(@abs(parsed.info.bitpix));
        meta = parsed.meta;
        // FITS is big-endian — convert 16-bit to LE for JXL
        if (bps == 16) {
            var i: usize = 0;
            while (i + 1 < pixels.len) : (i += 2) {
                const tmp = pixels[i];
                pixels[i] = pixels[i + 1];
                pixels[i + 1] = tmp;
            }
        }
    } else if (std.mem.eql(u8, codec_name, "nifti")) {
        const parsed = nifti_mod.parseNifti(allocator, content) catch return null;
        pixels = parsed.voxels;
        // NIfTI 3D: treat as width*height*slices grayscale image
        // JXL encodes as a single 2D image with height = original_height * slices
        const w = parsed.info.dim[1];
        const h = parsed.info.dim[2];
        const slices: u32 = if (parsed.info.dim[0] >= 3 and parsed.info.dim[3] > 0) parsed.info.dim[3] else 1;
        width = w;
        height = h * slices;
        channels = 1; // grayscale
        bps = parsed.info.bitpix;
        meta = parsed.meta;
    } else if (std.mem.eql(u8, codec_name, "dicom")) {
        const parsed = dicom_mod.parseDicom(allocator, content) catch return null;
        pixels = parsed.pixels;
        width = parsed.info.width;
        height = parsed.info.height;
        channels = @as(u32, parsed.info.samples_per_pixel);
        bps = @as(u32, parsed.info.bits_allocated);
        meta = parsed.meta;
    } else {
        return null;
    }

    // Encode pixels to JXL lossless
    const fmt = jxl_mod.PixelFormat{ .width = width, .height = height, .num_channels = channels, .bits_per_sample = bps };
    const jxl_data = jxl_mod.pixelsToJxl(allocator, pixels, fmt) catch {
        allocator.free(pixels);
        allocator.free(meta);
        return null;
    };
    allocator.free(pixels);

    // Size check: JXL + meta must be < 90% of original
    if (jxl_data.len + meta.len >= content.len * 9 / 10) {
        allocator.free(jxl_data);
        allocator.free(meta);
        return null;
    }

    // Build result entries
    const entries = try allocator.alloc(ExpandedEntry, 2);
    entries[0] = .{
        .path_suffix = try allocator.dupe(u8, "__meta__"),
        .content = meta,
        .is_dir = false,
        .jxl_source_format = &.{},
        .gz_level = 0,
    };
    entries[1] = .{
        .path_suffix = try allocator.dupe(u8, "__pixels__.jxl"),
        .content = jxl_data,
        .is_dir = false,
        .jxl_source_format = codec_name,
        .gz_level = 0,
    };

    return ExpandResult{
        .container_type = codec_name,
        .entries = entries,
        .allocator = allocator,
    };
}

/// Expand an audio format (WAV or AIFF) to FLAC.
fn expandAudioFormat(
    allocator: Allocator,
    content: []const u8,
    codec_name: []const u8,
) !?ExpandResult {
    if (!build_options.enable_flac) return null;
    if (content.len < 128) return null; // Minimum viable PDF size

    var pcm_samples: []u8 = undefined;
    var meta: []u8 = undefined;
    var num_channels: u16 = undefined;
    var sample_rate: u32 = undefined;
    var bits_per_sample: u16 = undefined;
    var num_frames: u32 = undefined;

    if (std.mem.eql(u8, codec_name, "wav")) {
        const parsed = wav_mod.parseWav(allocator, content) catch return null;
        pcm_samples = parsed.samples;
        meta = parsed.original;
        num_channels = parsed.info.num_channels;
        sample_rate = parsed.info.sample_rate;
        bits_per_sample = parsed.info.bits_per_sample;
        num_frames = parsed.info.num_samples;
    } else if (std.mem.eql(u8, codec_name, "aiff")) {
        const parsed = aiff_mod.parseAiff(allocator, content) catch return null;
        pcm_samples = parsed.samples;
        meta = parsed.meta;
        num_channels = parsed.info.num_channels;
        sample_rate = parsed.info.sample_rate;
        bits_per_sample = parsed.info.bits_per_sample;
        num_frames = parsed.info.num_samples;
    } else return null;

    const flac_data = flac_mod.encodePcmToFlac(
        allocator, pcm_samples, num_channels, sample_rate, bits_per_sample, num_frames,
    ) catch {
        allocator.free(pcm_samples);
        allocator.free(meta);
        return null;
    };
    allocator.free(pcm_samples);

    // Size check
    if (flac_data.len + meta.len >= content.len * 9 / 10) {
        allocator.free(flac_data);
        allocator.free(meta);
        return null;
    }

    const entries = try allocator.alloc(ExpandedEntry, 2);
    entries[0] = .{
        .path_suffix = try allocator.dupe(u8, "__meta__"),
        .content = meta,
        .is_dir = false,
        .jxl_source_format = &.{},
        .gz_level = 0,
    };
    entries[1] = .{
        .path_suffix = try allocator.dupe(u8, "__audio__.flac"),
        .content = flac_data,
        .is_dir = false,
        .jxl_source_format = &.{},
        .gz_level = 0,
    };

    return ExpandResult{
        .container_type = codec_name,
        .entries = entries,
        .allocator = allocator,
    };
}

// ── Public API ───────────────────────────────────────────────────────────


/// Expand a PDF into shell + JXL-transcoded image children.
fn expandPdf(allocator: Allocator, content: []const u8) !?ExpandResult {
    if (content.len < 128) return null; // Minimum viable PDF size

    // Phase 1: Decompress FlateDecode content streams for better LZMA2 compression
    var working: []u8 = undefined;
    var owns_working = false;

    // Phase 1: Decompress FlateDecode content streams → rewrite PDF
    // This makes text/operators available as raw data for LZMA2 and
    // ensures image stream offsets are correct for the working PDF.
    blk: {
        const content_streams = pdf_mod.findFlateContentStreams(allocator, content) catch break :blk;
        defer allocator.free(content_streams);
            if (content_streams.len == 0) break :blk;

        var replacements = std.ArrayListUnmanaged(pdf_mod.StreamReplacement){};
        defer {
            for (replacements.items) |rep| allocator.free(@constCast(rep.new_data));
            replacements.deinit(allocator);
        }

        for (content_streams) |cs| {
            const stream_data = content[cs.stream_start..cs.stream_end];
            const decompressed = pdf_mod.zlibDecompress(allocator, stream_data) catch continue;
            try replacements.append(allocator, .{
                .stream_start = cs.stream_start,
                .original_length = cs.len(),
                .new_data = decompressed,
            });
        }

            if (replacements.items.len > 0) {
            if (pdf_mod.rewritePdfWithStreams(allocator, content, replacements.items) catch null) |expanded| {
                working = expanded;
                owns_working = true;
                        } else {
                        }
        }
    }

    if (!owns_working) {
        working = try allocator.alloc(u8, content.len);
        @memcpy(working, content);
        owns_working = true;
    }
    defer if (owns_working) allocator.free(working);

    // Phase 2: Find JPEG image streams
    const jpeg_streams = pdf_mod.findJpegStreams(allocator, working) catch &.{};
    defer if (jpeg_streams.len > 0) allocator.free(jpeg_streams);

    // Phase 3: Find FlateDecode image streams
    const flate_streams = pdf_mod.findFlateImageStreams(allocator, working) catch &.{};
    defer if (flate_streams.len > 0) allocator.free(flate_streams);

    if (jpeg_streams.len == 0 and flate_streams.len == 0) return null;

    // Phase 4: Transcode JPEG streams to JXL (parallel)
    const jxl_jpeg_bufs = try allocator.alloc(?[]u8, jpeg_streams.len);
    defer {
        for (jxl_jpeg_bufs) |buf| if (buf) |b| allocator.free(b);
        allocator.free(jxl_jpeg_bufs);
    }

    // Simple sequential transcoding (threading can be added later with std.Thread)
    for (jpeg_streams, 0..) |stream, i| {
        const jpeg_data = working[stream.stream_start..][0..stream.len()];
        jxl_jpeg_bufs[i] = jxl_mod.jpegToJxl(allocator, jpeg_data) catch null;
    }

    // Phase 5: Transcode FlateDecode image streams to JXL
    const jxl_flate_bufs = try allocator.alloc(?[]u8, flate_streams.len);
    defer {
        for (jxl_flate_bufs) |buf| if (buf) |b| allocator.free(b);
        allocator.free(jxl_flate_bufs);
    }

    for (flate_streams, 0..) |stream, i| {
        const stream_data = working[stream.stream_start..][0..stream.len()];
        // Defilter + decode to pixels
        const defiltered = pdf_mod.defilterPdfFlate(
            allocator, stream_data,
            stream.columns, stream.colors, stream.bits_per_component, stream.predictor,
        ) catch { jxl_flate_bufs[i] = null; continue; };
        defer allocator.free(defiltered);

        const fmt = jxl_mod.PixelFormat{
            .width = stream.width, .height = stream.height,
            .num_channels = stream.colors, .bits_per_sample = stream.bits_per_component,
        };
        jxl_flate_bufs[i] = jxl_mod.pixelsToJxl(allocator, defiltered, fmt) catch null;
    }

    // Count successful transcodings
    var num_jxl: usize = 0;
    for (jxl_jpeg_bufs) |buf| if (buf != null) { num_jxl += 1; };
    for (jxl_flate_bufs) |buf| if (buf != null) { num_jxl += 1; };
    if (num_jxl == 0) return null;

    // Build entries: __body__ (shell) + __img_N.jxl children
    const num_entries = 1 + num_jxl;
    const entries = try allocator.alloc(ExpandedEntry, num_entries);

    // __body__ = working PDF (with content streams decompressed)
    entries[0] = .{
        .path_suffix = try allocator.dupe(u8, "__body__"),
        .content = try allocator.dupe(u8, working),
        .is_dir = false,
        .jxl_source_format = &.{},
        .gz_level = 0,
    };

    var entry_idx: usize = 1;

    // JPEG images
    for (jpeg_streams, 0..) |stream, i| {
        const jxl = jxl_jpeg_bufs[i] orelse continue;
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "__img_{d}.jxl", .{i}) catch continue;

        const owned_jxl = try allocator.alloc(u8, jxl.len);
        @memcpy(owned_jxl, jxl);

        entries[entry_idx] = .{
            .path_suffix = try allocator.dupe(u8, name),
            .content = owned_jxl,
            .is_dir = false,
            .jxl_source_format = "jpeg",
            .gz_level = 0,
            .pdf_offset = stream.stream_start,
            .pdf_length = @intCast(stream.len()),
        };
        entry_idx += 1;
    }

    // FlateDecode images
    for (flate_streams, 0..) |stream, i| {
        const jxl = jxl_flate_bufs[i] orelse continue;
        var name_buf: [32]u8 = undefined;
        const img_idx = jpeg_streams.len + i;
        const name = std.fmt.bufPrint(&name_buf, "__img_{d}.jxl", .{img_idx}) catch continue;

        const owned_jxl = try allocator.alloc(u8, jxl.len);
        @memcpy(owned_jxl, jxl);

        entries[entry_idx] = .{
            .path_suffix = try allocator.dupe(u8, name),
            .content = owned_jxl,
            .is_dir = false,
            .jxl_source_format = "flate",
            .gz_level = 0,
            .pdf_offset = stream.stream_start,
            .pdf_length = stream.len(),
        };
        entry_idx += 1;
    }

    // Trim entries array to actual count
    const final_entries = try allocator.realloc(entries, entry_idx);

    return ExpandResult{
        .container_type = "pdf",
        .entries = final_entries,
        .allocator = allocator,
    };
}


/// Expand a ZIP into individual file entries.
fn expandZip(allocator: Allocator, content: []const u8) !?ExpandResult {
    if (content.len < 30) return null;

    // Check for encryption
    if (zip_mod.hasEncryptedEntries(allocator, content) catch false) return null;

    const zip_entries = zip_mod.readEntries(allocator, content) catch return null;
    defer allocator.free(zip_entries);

    if (zip_entries.len == 0) return null;

    const entries = try allocator.alloc(ExpandedEntry, zip_entries.len);
    var valid: usize = 0;

    for (zip_entries) |ze| {
        const extracted = zip_mod.extractEntry(allocator, ze) catch continue;

        entries[valid] = .{
            .path_suffix = try allocator.dupe(u8, ze.filename),
            .content = extracted,
            .is_dir = ze.filename.len > 0 and ze.filename[ze.filename.len - 1] == '/',
            .jxl_source_format = &.{},
            .gz_level = 0,
            .zip_comp = ze.compression_method,
        };
        valid += 1;
    }

    if (valid == 0) {
        allocator.free(entries);
        return null;
    }

    const final = try allocator.realloc(entries, valid);
    return ExpandResult{
        .container_type = "zip",
        .entries = final,
        .allocator = allocator,
    };
}

/// Attempt to expand a file's content into a container representation.
/// Returns null if the format is not recognized or expansion isn't worthwhile.
/// The caller owns the returned ExpandResult and must call deinit().
pub fn expandFile(allocator: Allocator, content: []const u8, codec_name: []const u8) !?ExpandResult {
    // Pixel-based formats (→ JXL)
    if (std.mem.eql(u8, codec_name, "bmp") or
        std.mem.eql(u8, codec_name, "tga") or
        std.mem.eql(u8, codec_name, "tiff") or
        std.mem.eql(u8, codec_name, "png") or
        std.mem.eql(u8, codec_name, "gif") or
        std.mem.eql(u8, codec_name, "fits") or
        std.mem.eql(u8, codec_name, "dicom") or
        std.mem.eql(u8, codec_name, "nifti"))
    {
        return expandPixelFormat(allocator, content, codec_name, 1024);
    }

    // Audio formats (→ FLAC)
    if (std.mem.eql(u8, codec_name, "wav") or
        std.mem.eql(u8, codec_name, "aiff"))
    {
        return expandAudioFormat(allocator, content, codec_name);
    }


    // Gzip
    if (std.mem.eql(u8, codec_name, "gz")) {
        if (content.len < 20) return null;
        const decompressed = pdf_mod.gzipDecompress(allocator, content) catch return null;
        const gz_level = pdf_mod.gzipGuessLevel(allocator, content, decompressed);

        const entries = try allocator.alloc(ExpandedEntry, 1);
        entries[0] = .{
            .path_suffix = try allocator.dupe(u8, "__body__"),
            .content = decompressed,
            .is_dir = false,
            .jxl_source_format = &.{},
            .gz_level = gz_level,
        };
        return ExpandResult{
            .container_type = "gz",
            .entries = entries,
            .allocator = allocator,
        };
    }


    // Tar
    if (std.mem.eql(u8, codec_name, "tar")) {
        if (content.len < 128) return null; // Minimum viable PDF size

        var parsed = tar_mod.parseTar(allocator, content) catch return null;
        defer parsed.deinit();

        if (parsed.entries.len == 0) return null;

        // Build metadata: [u64_le count][u64_le trailer_len][trailer]
        //                 [512-byte header + u8 typeflag] * count
        const count = parsed.entries.len;
        const meta_len = 8 + 8 + parsed.trailer.len + count * 513;
        const meta = allocator.alloc(u8, meta_len) catch return null;

        std.mem.writeInt(u64, meta[0..8], count, .little);
        std.mem.writeInt(u64, meta[8..16], parsed.trailer.len, .little);
        if (parsed.trailer.len > 0)
            @memcpy(meta[16..][0..parsed.trailer.len], parsed.trailer);
        var moff: usize = 16 + parsed.trailer.len;
        for (parsed.entries) |entry| {
            @memcpy(meta[moff..][0..512], &entry.header);
            moff += 512;
            meta[moff] = entry.typeflag;
            moff += 1;
        }

        // Build entries: __meta__ + one entry per tar member
        const num_entries = 1 + count;
        const entries = allocator.alloc(ExpandedEntry, num_entries) catch {
            allocator.free(meta);
            return null;
        };

        entries[0] = .{
            .path_suffix = allocator.dupe(u8, "__meta__") catch { allocator.free(meta); allocator.free(entries); return null; },
            .content = meta,
            .is_dir = false,
            .jxl_source_format = &.{},
            .gz_level = 0,
        };

        for (parsed.entries, 0..) |entry, i| {
            // Path: __entry_NNNN/original_path
            var idx_buf: [32]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "__entry_{d:0>4}/", .{i}) catch unreachable;
            const suffix_len = idx_str.len + entry.path.len;
            const suffix = allocator.alloc(u8, suffix_len) catch return null;
            @memcpy(suffix[0..idx_str.len], idx_str);
            @memcpy(suffix[idx_str.len..], entry.path);

            var child_content: []u8 = &.{};
            if (entry.content.len > 0) {
                child_content = allocator.alloc(u8, entry.content.len) catch return null;
                @memcpy(child_content, entry.content);
            }

            entries[1 + i] = .{
                .path_suffix = suffix,
                .content = child_content,
                .is_dir = entry.typeflag == '5',
                .jxl_source_format = &.{},
                .gz_level = 0,
            };
        }

        return ExpandResult{
            .container_type = "tar",
            .entries = entries,
            .allocator = allocator,
        };
    }


    // JPEG → JXL (lossless JPEG transcode, not pixel-based)
    if (std.mem.eql(u8, codec_name, "jpeg")) {
        if (content.len < 128) return null; // Minimum viable PDF size

        const jxl_data = jxl_mod.jpegToJxl(allocator, content) catch return null;

        // Size check: JXL must be < 85% of original (JPEG is already compressed)
        if (jxl_data.len >= content.len * 85 / 100) {
            allocator.free(jxl_data);
            return null;
        }

        // Single child: __data__.jxl (the JXL transcoded JPEG)
        const entries = try allocator.alloc(ExpandedEntry, 1);
        entries[0] = .{
            .path_suffix = try allocator.dupe(u8, "__body__.jxl"),
            .content = jxl_data,
            .is_dir = false,
            .jxl_source_format = "jpeg",
            .gz_level = 0,
        };
        return ExpandResult{
            .container_type = "jpeg",
            .entries = entries,
            .allocator = allocator,
        };
    }


    // PDF
    if (std.mem.eql(u8, codec_name, "pdf")) {
        return expandPdf(allocator, content);
    }
    // ZIP
    if (std.mem.eql(u8, codec_name, "zip")) {
        return expandZip(allocator, content);
    }

    return null;
}

/// Reconstruct a container's original file from its expanded children.
/// Returns the reconstructed bytes, or null on failure.
pub fn collapseContainer(
    allocator: Allocator,
    codec_name: []const u8,
    children: []const CollapseChild,
) !?[]u8 {





    // ZIP collapse: reconstruct ZIP from child entries with compression methods
    if (std.mem.eql(u8, codec_name, "zip")) {
        // Collect child entries (skip __meta__ if present, though ZIP doesn't use it)
        var zip_entries = std.ArrayListUnmanaged(zip_mod.ZipWriteEntry){};
        defer zip_entries.deinit(allocator);

        for (children) |child| {
            // Each child's inner_path is the path within the ZIP
            const comp_method: u16 = child.zip_comp;
            try zip_entries.append(allocator, .{
                .filename = child.inner_path,
                .content = child.content,
                .compression_method = comp_method,
                .last_modification_time = 0, // TODO H3: preserve from archive metadata
                .last_modification_date = 0, // TODO H3: preserve from archive metadata
                .external_attributes = 0,
            });
        }

        if (zip_entries.items.len == 0) return null;

        return zip_mod.createZip(allocator, zip_entries.items) catch null;
    }

    // PDF collapse: reconstruct from __body__ shell + __img_*.jxl children
    if (std.mem.eql(u8, codec_name, "pdf")) {
        var shell: ?[]const u8 = null;

        // Collect all children
        for (children) |child| {
            if (std.mem.eql(u8, child.inner_path, "__body__"))
                shell = child.content;
        }
        const shell_data = shell orelse return null;

        // Start with a mutable copy of the shell
        var pdf_buf = try allocator.alloc(u8, shell_data.len);
        @memcpy(pdf_buf, shell_data);

        // Track FlateDecode replacements for potential rewrite
        var flate_replacements = std.ArrayListUnmanaged(struct {
            start: u64,
            orig_len: u64,
            new_data: []u8,
        }){};
        defer {
            for (flate_replacements.items) |rep| allocator.free(rep.new_data);
            flate_replacements.deinit(allocator);
        }

        // Process each __img_*.jxl child
        for (children) |child| {
            if (!std.mem.startsWith(u8, child.inner_path, "__img_")) continue;
            if (!std.mem.endsWith(u8, child.inner_path, ".jxl")) continue;

            const po = child.pdf_offset;
            const pl = child.pdf_length;
            if (po == std.math.maxInt(u64) or pl == std.math.maxInt(u64)) continue;

            const is_flate = std.mem.eql(u8, child.jxl_source, "flate");

            if (is_flate) {
                // FlateDecode: JXL → pixels → refilter → zlib compress
                var px_fmt: jxl_mod.PixelFormat = undefined;
                const px = jxl_mod.jxlToPixels(allocator, child.content, &px_fmt) catch continue;
                defer allocator.free(px);

                // Refilter + zlib compress via FFI
                // This requires blip_pdf_refilter + blip_zlib_compress which are C FFI.
                // For now, skip FlateDecode reconstruction and rely on the C path.
                // The shell already has the decompressed content, which is fine for
                // most PDFs since we expanded FlateDecode streams in Phase 1.
                continue;
            } else {
                // JPEG: JXL → JPEG (lossless reverse transcode)
                const jpeg_data = jxl_mod.jxlToJpeg(allocator, child.content) catch continue;
                defer allocator.free(jpeg_data);

                // Splice JPEG back into PDF at the stored offset
                if (@as(usize, po) + jpeg_data.len <= pdf_buf.len and jpeg_data.len == @as(usize, pl)) {
                    @memcpy(pdf_buf[@as(usize, po)..][0..jpeg_data.len], jpeg_data);
                } else if (jpeg_data.len != @as(usize, pl)) {
                    // Size changed — need full PDF rewrite (rare for lossless JPEG→JXL roundtrip)
                    // For now, add to replacement list
                    const owned = try allocator.alloc(u8, jpeg_data.len);
                    @memcpy(owned, jpeg_data);
                    try flate_replacements.append(allocator, .{
                        .start = po,
                        .orig_len = pl,
                        .new_data = owned,
                    });
                }
            }
        }

        // If we have replacements that changed size, rewrite the whole PDF
        if (flate_replacements.items.len > 0) {
            // Convert to StreamReplacement format
            const reps = try allocator.alloc(pdf_mod.StreamReplacement, flate_replacements.items.len);
            defer allocator.free(reps);
            for (flate_replacements.items, 0..) |rep, ri| {
                reps[ri] = .{
                    .stream_start = @intCast(rep.start),
                    .original_length = @intCast(rep.orig_len),
                    .new_data = rep.new_data,
                };
            }
            if (pdf_mod.rewritePdfWithStreams(allocator, pdf_buf, reps) catch null) |rewritten| {
                allocator.free(pdf_buf);
                return rewritten;
            }
            // Use blip_pdf_rewrite_streams for size-changing replacements
            // For now this is handled by the C path — the Zig path only handles
            // same-size JPEG replacements (which is the common case for lossless JPEG↔JXL)
        }

        return pdf_buf;
    }

    // JPEG collapse: JXL → JPEG (lossless reverse transcode)
    if (std.mem.eql(u8, codec_name, "jpeg")) {
        var jxl_content: ?[]const u8 = null;
        for (children) |child| {
            if (std.mem.eql(u8, child.inner_path, "__body__.jxl"))
                jxl_content = child.content;
        }
        const jxl_data = jxl_content orelse return null;
        return jxl_mod.jxlToJpeg(allocator, jxl_data) catch null;
    }

    // Tar collapse: reconstruct from __meta__ headers + child content
    if (std.mem.eql(u8, codec_name, "tar")) {
        var meta_content: ?[]const u8 = null;
        for (children) |child| {
            if (std.mem.eql(u8, child.inner_path, "__meta__"))
                meta_content = child.content;
        }
        const meta = meta_content orelse return null;
        if (meta.len < 16) return null;

        const entry_count = std.mem.readInt(u64, meta[0..8], .little);
        const trailer_len = std.mem.readInt(u64, meta[8..16], .little);
        const trailer = if (trailer_len > 0) meta[16..][0..@as(usize, trailer_len)] else &[_]u8{};
        const hdr_start = 16 + @as(usize, trailer_len);

        // Calculate total tar size
        var tar_size: usize = 0;
        for (0..@as(usize, entry_count)) |ei| {
            const hdr = meta[hdr_start + ei * 513 ..][0..512];
            // Read size from octal field at offset 124..136
            var sz: u64 = 0;
            for (hdr[124..136]) |ch| {
                if (ch == 0 or ch == ' ') break;
                if (ch < '0' or ch > '7') { sz = 0; break; }
                sz = sz * 8 + @as(u64, ch - '0');
            }
            tar_size += 512; // header
            tar_size += ((@as(usize, sz) + 511) & ~@as(usize, 511)); // padded content
        }
        tar_size += if (trailer_len > 0) @as(usize, trailer_len) else 1024;

        const result = try allocator.alloc(u8, tar_size);
        @memset(result, 0);

        var toff: usize = 0;
        for (0..@as(usize, entry_count)) |ei| {
            const hdr = meta[hdr_start + ei * 513 ..][0..512];
            @memcpy(result[toff..][0..512], hdr);
            toff += 512;

            var sz: u64 = 0;
            for (hdr[124..136]) |ch| {
                if (ch == 0 or ch == ' ') break;
                if (ch < '0' or ch > '7') { sz = 0; break; }
                sz = sz * 8 + @as(u64, ch - '0');
            }

            if (sz > 0) {
                // Find matching child by __entry_NNNN/ prefix
                var idx_buf: [32]u8 = undefined;
                const idx_prefix = std.fmt.bufPrint(&idx_buf, "__entry_{d:0>4}/", .{ei}) catch unreachable;

                for (children) |child| {
                    if (child.inner_path.len > idx_prefix.len and
                        std.mem.eql(u8, child.inner_path[0..idx_prefix.len], idx_prefix))
                    {
                        const copy_len = @min(child.content.len, @as(usize, sz));
                        if (toff + copy_len <= tar_size)
                            @memcpy(result[toff..][0..copy_len], child.content[0..copy_len]);
                        break;
                    }
                }
                toff += ((@as(usize, sz) + 511) & ~@as(usize, 511));
            }
        }

        // Write trailer
        if (trailer.len > 0 and toff + trailer.len <= tar_size)
            @memcpy(result[toff..][0..trailer.len], trailer);

        return result;
    }

    // Gzip collapse: recompress __body__ with stored level
    if (std.mem.eql(u8, codec_name, "gz")) {
        var body_content: ?[]const u8 = null;
        var gz_level: u8 = 6; // default
        for (children) |child| {
            if (std.mem.eql(u8, child.inner_path, "__body__")) {
                body_content = child.content;
                // gz_level stored in zip_comp field (repurposed during expansion)
                if (child.zip_comp != 0xFFFF and child.zip_comp >= 1 and child.zip_comp <= 9) {
                    gz_level = @truncate(child.zip_comp);
                }
            }
        }
        const body = body_content orelse return null;
        const gz_data = pdf_mod.gzipCompressLevel(allocator, body, gz_level) catch return null;
        return gz_data;
    }

    // Find __meta__ and __pixels__.jxl / __audio__.flac children
    var meta_content: ?[]const u8 = null;
    var pixel_content: ?[]const u8 = null;
    var audio_content: ?[]const u8 = null;

    for (children) |child| {
        if (std.mem.eql(u8, child.inner_path, "__meta__"))
            meta_content = child.content
        else if (std.mem.eql(u8, child.inner_path, "__pixels__.jxl"))
            pixel_content = child.content
        else if (std.mem.eql(u8, child.inner_path, "__audio__.flac"))
            audio_content = child.content;
    }

    // GIF: just return __meta__ (it IS the original file)
    if (std.mem.eql(u8, codec_name, "gif")) {
        const meta = meta_content orelse return null;
        const result = try allocator.alloc(u8, meta.len);
        @memcpy(result, meta);
        return result;
    }

    // Audio collapse (WAV, AIFF)
    if (std.mem.eql(u8, codec_name, "wav") or std.mem.eql(u8, codec_name, "aiff")) {
        if (!build_options.enable_flac) return null;
        const meta = meta_content orelse return null;
        const flac_data = audio_content orelse return null;

        var dec_channels: u32 = 0;
        var dec_rate: u32 = 0;
        var dec_bps: u32 = 0;
        var dec_total: u64 = 0;
        const pcm = flac_mod.decodeFlacToPcm(allocator, flac_data, &dec_channels, &dec_rate, &dec_bps, &dec_total) catch return null;
        defer allocator.free(pcm);

        if (std.mem.eql(u8, codec_name, "wav")) {
            return reconstructWav(allocator, meta, pcm);
        } else {
            return reconstructAiff(allocator, meta, pcm, dec_bps, dec_channels * @as(u32, @truncate(dec_total)));
        }
    }

    // Pixel collapse (BMP, TGA, TIFF, PNG, FITS, DICOM)
    if (pixel_content != null and meta_content != null) {
        const jxl_data = pixel_content.?;
        const meta = meta_content.?;

        // Decode JXL to pixels
        var px_fmt: jxl_mod.PixelFormat = undefined;
        const px_pixels = jxl_mod.jxlToPixels(allocator, jxl_data, &px_fmt) catch return null;
        defer allocator.free(px_pixels);

        if (std.mem.eql(u8, codec_name, "bmp")) {
            return reconstructBmp(allocator, meta, px_pixels, px_fmt.width, px_fmt.height);
        } else if (std.mem.eql(u8, codec_name, "tga")) {
            return reconstructTga(allocator, meta, px_pixels, px_fmt.width, px_fmt.height);
        } else if (std.mem.eql(u8, codec_name, "png")) {
            return reconstructPng(allocator, meta, px_pixels, px_fmt.width, px_fmt.height, px_fmt.num_channels, px_fmt.bits_per_sample);
        } else if (std.mem.eql(u8, codec_name, "tiff") or
            std.mem.eql(u8, codec_name, "fits") or
            std.mem.eql(u8, codec_name, "dicom") or
        std.mem.eql(u8, codec_name, "nifti"))
        {
            return reconstructFromTemplate(allocator, meta, px_pixels, codec_name, px_fmt.bits_per_sample);
        }
    }

    return null;
}

// ── Reconstruction helpers ───────────────────────────────────────────────

fn reconstructBmp(allocator: Allocator, meta: []const u8, pixels: []const u8, width: u32, height: u32) !?[]u8 {
    if (meta.len < 7) return null;
    const top_down = meta[0] != 0;
    const bpp = std.mem.readInt(u16, meta[1..3], .little);
    const row_stride = std.mem.readInt(u32, meta[3..7], .little);
    const header_src = meta[7..];

    const header_bytes = try allocator.alloc(u8, header_src.len);
    defer allocator.free(header_bytes);
    @memcpy(header_bytes, header_src);

    const channels: u8 = if (bpp == 32) 4 else 3;
    const header = bmp_mod.BmpHeader{
        .header_bytes = header_bytes,
        .width = width, .height = height, .abs_height = height,
        .top_down = top_down, .channels = channels,
        .bits_per_pixel = bpp, .row_stride = row_stride,
        .allocator = allocator,
    };
    return bmp_mod.encodeBmp(allocator, pixels, header) catch null;
}

fn reconstructTga(allocator: Allocator, meta: []const u8, pixels: []const u8, width: u32, height: u32) !?[]u8 {
    if (meta.len < 10) return null;
    const top_down = meta[0] != 0;
    const bpp = meta[1];
    const footer_len = std.mem.readInt(u32, meta[6..10], .little);
    const header_bytes_len = meta.len - 10 - @as(usize, footer_len);
    const header_src = meta[10..][0..header_bytes_len];
    const footer_src = if (footer_len > 0) meta[10 + header_bytes_len ..] else &[_]u8{};

    const header_bytes = try allocator.alloc(u8, header_bytes_len);
    defer allocator.free(header_bytes);
    @memcpy(header_bytes, header_src);

    const channels: u8 = if (bpp == 32) 4 else 3;
    const header = tga_mod.TgaHeader{
        .header_bytes = header_bytes,
        .width = @intCast(width), .height = @intCast(height),
        .channels = channels, .bits_per_pixel = bpp,
        .top_down = top_down, .allocator = allocator,
    };
    return tga_mod.encodeTga(allocator, pixels, header, footer_src) catch null;
}

fn reconstructPng(allocator: Allocator, meta: []const u8, pixels: []const u8, width: u32, height: u32, num_channels: u32, bit_depth: u32) !?[]u8 {
    if (meta.len < 4) return null;
    const head_len = std.mem.readInt(u32, meta[0..4], .big);
    if (4 + head_len > meta.len) return null;
    const pre_idat = meta[4..][0..head_len];
    const post_idat = meta[4 + head_len ..];

    const color_type: png_mod.PngColorType = switch (num_channels) {
        1 => .grayscale,
        2 => .grayscale_alpha,
        3 => .rgb,
        4 => .rgba,
        else => return null,
    };
    const info = png_mod.PngInfo{
        .width = width, .height = height,
        .bit_depth = @intCast(bit_depth),
        .color_type = color_type,
        .channels = @intCast(num_channels),
        .bytes_per_sample = if (bit_depth == 16) 2 else 1,
        .interlace_method = 0,
    };
    return png_mod.encodePng(allocator, pixels, info, pre_idat, post_idat) catch null;
}

/// Reconstruct TIFF, FITS, or DICOM from compact template + pixels.
fn reconstructFromTemplate(allocator: Allocator, meta: []const u8, pixels: []u8, codec_name: []const u8, bps: u32) !?[]u8 {
    // FITS uses big-endian, need to convert back
    if (std.mem.eql(u8, codec_name, "fits") and bps == 16) {
        var i: usize = 0;
        while (i + 1 < pixels.len) : (i += 2) {
            const tmp = pixels[i];
            pixels[i] = pixels[i + 1];
            pixels[i + 1] = tmp;
        }
    }

    // TIFF uses BE meta prefix, FITS uses BE, DICOM uses LE
    var file_size: u32 = undefined;
    var pixel_offset: u32 = undefined;
    var pixel_size: u32 = undefined;
    var meta_prefix: usize = undefined;

    if (std.mem.eql(u8, codec_name, "tiff")) {
        if (meta.len < 20) return null;
        file_size = std.mem.readInt(u32, meta[0..4], .little);
        const num_strips = std.mem.readInt(u32, meta[4..8], .little);
        const first_pixel = std.mem.readInt(u32, meta[8..12], .little);
        const pre_len = std.mem.readInt(u32, meta[12..16], .little);
        const post_len = std.mem.readInt(u32, meta[16..20], .little);
        const strip_map_len = @as(usize, num_strips) * 8;
        meta_prefix = 20 + strip_map_len;

        const result = try allocator.alloc(u8, file_size);
        @memset(result, 0);

        // Copy pre-pixel bytes
        if (pre_len > 0 and meta_prefix + pre_len <= meta.len)
            @memcpy(result[0..pre_len], meta[meta_prefix..][0..pre_len]);

        // Copy post-pixel bytes
        if (post_len > 0 and meta_prefix + pre_len + post_len <= meta.len) {
            const post_offset = file_size - post_len;
            @memcpy(result[post_offset..][0..post_len], meta[meta_prefix + pre_len ..][0..post_len]);
        }

        // Write pixels into strip regions
        var pix_off: usize = 0;
        for (0..num_strips) |si| {
            const strip_offset = std.mem.readInt(u32, meta[20 + si * 8 ..][0..4], .little);
            const strip_size = std.mem.readInt(u32, meta[20 + si * 8 + 4 ..][0..4], .little);
            const copy_len = @min(@as(usize, strip_size), pixels.len - @min(pix_off, pixels.len));
            if (strip_offset + copy_len <= file_size)
                @memcpy(result[strip_offset..][0..copy_len], pixels[pix_off..][0..copy_len]);
            pix_off += strip_size;
        }
        _ = first_pixel;
        return result;
    }

    // FITS and DICOM: same compact format [u32 file_size][u32 pixel_offset][u32 pixel_size]
    if (meta.len < 12) return null;

    if (std.mem.eql(u8, codec_name, "fits")) {
        file_size = std.mem.readInt(u32, meta[0..4], .big);
        pixel_offset = std.mem.readInt(u32, meta[4..8], .big);
        pixel_size = std.mem.readInt(u32, meta[8..12], .big);
    } else {
        // DICOM: LE
        file_size = std.mem.readInt(u32, meta[0..4], .little);
        pixel_offset = std.mem.readInt(u32, meta[4..8], .little);
        pixel_size = std.mem.readInt(u32, meta[8..12], .little);
    }
    meta_prefix = 12;

    const result = try allocator.alloc(u8, file_size);
    @memset(result, 0);

    // Copy pre-pixel header from meta
    if (pixel_offset <= file_size and meta_prefix + pixel_offset <= meta.len)
        @memcpy(result[0..pixel_offset], meta[meta_prefix..][0..pixel_offset]);

    // Copy pixels
    const copy_len = @min(@as(usize, pixel_size), pixels.len);
    if (pixel_offset + copy_len <= file_size)
        @memcpy(result[pixel_offset..][0..copy_len], pixels[0..copy_len]);

    // Copy post-pixel data
    const post_meta_off = meta_prefix + pixel_offset;
    if (post_meta_off < meta.len) {
        const post_len = meta.len - post_meta_off;
        const post_start = @as(usize, pixel_offset) + @as(usize, pixel_size);
        if (post_start + post_len <= file_size)
            @memcpy(result[post_start..][0..post_len], meta[post_meta_off..][0..post_len]);
    }

    return result;
}

fn reconstructWav(allocator: Allocator, meta: []const u8, pcm: []const u8) !?[]u8 {
    if (meta.len < 12) return null;
    const file_size = std.mem.readInt(u32, meta[0..4], .little);
    const data_offset = std.mem.readInt(u32, meta[4..8], .little);
    const pre_data = meta[12..][0..data_offset];
    const post_data = if (12 + data_offset < meta.len) meta[12 + data_offset ..] else &[_]u8{};

    const result = try allocator.alloc(u8, file_size);
    @memset(result, 0);
    if (data_offset <= file_size) @memcpy(result[0..data_offset], pre_data);
    const pcm_copy = @min(pcm.len, file_size - @min(data_offset, file_size));
    if (data_offset + pcm_copy <= file_size)
        @memcpy(result[data_offset..][0..pcm_copy], pcm[0..pcm_copy]);
    const post_start = data_offset + pcm_copy;
    if (post_data.len > 0 and post_start + post_data.len <= file_size)
        @memcpy(result[post_start..][0..post_data.len], post_data);
    return result;
}

fn reconstructAiff(allocator: Allocator, meta: []const u8, pcm: []const u8, bps: u32, total_sample_count: u32) !?[]u8 {
    if (meta.len < 13) return null;
    const file_size = std.mem.readInt(u32, meta[0..4], .big);
    const ssnd_offset = std.mem.readInt(u32, meta[4..8], .big);
    const pre_ssnd = meta[13..][0..ssnd_offset];
    const post_ssnd = if (13 + ssnd_offset < meta.len) meta[13 + ssnd_offset ..] else &[_]u8{};

    const result = try allocator.alloc(u8, file_size);
    @memset(result, 0);
    if (ssnd_offset <= file_size) @memcpy(result[0..ssnd_offset], pre_ssnd);

    // Convert LE PCM back to BE
    const bytes_per_sample: usize = (bps + 7) / 8;
    var pcm_off: usize = ssnd_offset;
    for (0..total_sample_count) |i| {
        const src_off = i * bytes_per_sample;
        if (src_off + bytes_per_sample > pcm.len or pcm_off + bytes_per_sample > file_size) break;
        switch (bytes_per_sample) {
            1 => result[pcm_off] = pcm[src_off],
            2 => {
                result[pcm_off] = pcm[src_off + 1];
                result[pcm_off + 1] = pcm[src_off];
            },
            3 => {
                result[pcm_off] = pcm[src_off + 2];
                result[pcm_off + 1] = pcm[src_off + 1];
                result[pcm_off + 2] = pcm[src_off];
            },
            else => {},
        }
        pcm_off += bytes_per_sample;
    }

    if (post_ssnd.len > 0 and pcm_off + post_ssnd.len <= file_size)
        @memcpy(result[pcm_off..][0..post_ssnd.len], post_ssnd);
    return result;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "detectCodec identifies ALL supported formats" {
    // JPEG: FF D8 FF
    try testing.expectEqualStrings("jpeg", detectCodec(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 }).?);

    // PDF: %PDF-
    try testing.expectEqualStrings("pdf", detectCodec("%PDF-1.4 test content here!!" ++ &[_]u8{0} ** 4).?);

    // PNG: 89 50 4E 47 0D 0A 1A 0A
    try testing.expectEqualStrings("png", detectCodec(&[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }).?);

    // BMP: BM + 16 bytes of header
    try testing.expectEqualStrings("bmp", detectCodec(&[_]u8{ 'B', 'M', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).?);

    // TGA: type=2, color_map=0, bpp=24, width/height non-zero
    {
        var tga: [18]u8 = .{0} ** 18;
        tga[2] = 2; // image type: uncompressed true-color
        tga[12] = 1; // width low byte
        tga[14] = 1; // height low byte
        tga[16] = 24; // bits per pixel
        try testing.expectEqualStrings("tga", detectCodec(&tga).?);
    }

    // TIFF LE: II + 42
    try testing.expectEqualStrings("tiff", detectCodec(&[_]u8{ 'I', 'I', 42, 0 }).?);
    // TIFF BE: MM + 0x002A
    try testing.expectEqualStrings("tiff", detectCodec(&[_]u8{ 'M', 'M', 0, 42 }).?);

    // GIF: GIF89a
    try testing.expectEqualStrings("gif", detectCodec("GIF89a" ++ &[_]u8{0} ** 2).?);
    try testing.expectEqualStrings("gif", detectCodec("GIF87a" ++ &[_]u8{0} ** 2).?);

    // DICOM: 128-byte preamble + "DICM"
    {
        var dcm: [136]u8 = .{0} ** 136;
        dcm[128] = 'D'; dcm[129] = 'I'; dcm[130] = 'C'; dcm[131] = 'M';
        try testing.expectEqualStrings("dicom", detectCodec(&dcm).?);
    }

    // FITS: "SIMPLE  =                    T" at start
    try testing.expectEqualStrings("fits", detectCodec("SIMPLE  =                    T" ++ &[_]u8{' '} ** 50).?);

    // NIfTI: sizeof_hdr=348 LE + magic "n+1\0" at offset 344
    {
        var nii: [348]u8 = .{0} ** 348;
        std.mem.writeInt(u32, nii[0..4], 348, .little);
        nii[344] = 'n'; nii[345] = '+'; nii[346] = '1'; nii[347] = 0;
        try testing.expectEqualStrings("nifti", detectCodec(&nii).?);
    }

    // AIFF: FORM....AIFF
    {
        var aiff: [12]u8 = .{0} ** 12;
        @memcpy(aiff[0..4], "FORM");
        @memcpy(aiff[8..12], "AIFF");
        try testing.expectEqualStrings("aiff", detectCodec(&aiff).?);
    }

    // WAV: RIFF....WAVE
    {
        var wav: [12]u8 = .{0} ** 12;
        @memcpy(wav[0..4], "RIFF");
        @memcpy(wav[8..12], "WAVE");
        try testing.expectEqualStrings("wav", detectCodec(&wav).?);
    }

    // tar: ustar magic at offset 257
    {
        var tar: [512]u8 = .{0} ** 512;
        tar[257] = 'u'; tar[258] = 's'; tar[259] = 't'; tar[260] = 'a'; tar[261] = 'r'; tar[262] = 0;
        try testing.expectEqualStrings("tar", detectCodec(&tar).?);
    }

    // gzip: 1F 8B
    try testing.expectEqualStrings("gz", detectCodec(&[_]u8{ 0x1F, 0x8B, 0x08, 0x00 }).?);

    // ZIP: PK\x03\x04
    try testing.expectEqualStrings("zip", detectCodec(&[_]u8{ 0x50, 0x4B, 0x03, 0x04 }).?);

    // Negative: random bytes
    try testing.expect(detectCodec(&[_]u8{ 0x00, 0x00, 0x00, 0x00 }) == null);
    try testing.expect(detectCodec(&[_]u8{ 0xDE, 0xAD }) == null);
    try testing.expect(detectCodec(&[_]u8{}) == null);
}

// ── Microbenchmarks ──────────────────────────────────────────────────────
// Only run in ReleaseFast (guarded by builtin.mode check).
// Prefix: "microbench:" for filtering.

const builtin = @import("builtin");

test "microbench: BMP expansion 64x64" {
    if (builtin.mode == .Debug) return;

    // Generate a 64x64 24-bit BMP in memory
    const bmp_mod_local = @import("bmp.zig");
    const alloc = testing.allocator;

    // Build BMP data
    const width: u32 = 64;
    const height: u32 = 64;
    const row_stride = (width * 3 + 3) & ~@as(u32, 3);
    const pixel_data_len = row_stride * height;
    const total = 54 + pixel_data_len;
    const bmp = try alloc.alloc(u8, total);
    defer alloc.free(bmp);
    @memset(bmp, 0);
    bmp[0] = 'B'; bmp[1] = 'M';
    std.mem.writeInt(u32, bmp[2..6], @intCast(total), .little);
    std.mem.writeInt(u32, bmp[10..14], 54, .little);
    std.mem.writeInt(u32, bmp[14..18], 40, .little);
    std.mem.writeInt(u32, bmp[18..22], width, .little);
    std.mem.writeInt(u32, bmp[22..26], height, .little);
    std.mem.writeInt(u16, bmp[26..28], 1, .little);
    std.mem.writeInt(u16, bmp[28..30], 24, .little);
    for (0..height) |y| {
        for (0..width) |x| {
            const off = 54 + y * row_stride + x * 3;
            bmp[off] = @truncate(x * 4);
            bmp[off + 1] = @truncate(y * 4);
            bmp[off + 2] = @truncate((x + y) * 2);
        }
    }

    _ = bmp_mod_local;

    // Warm up
    for (0..5) |_| {
        var r = expandFile(alloc, bmp, "bmp") catch null;
        if (r) |*res| res.deinit();
    }

    // Measure
    const iterations: u64 = 50;
    var timer = try std.time.Timer.start();
    _ = timer.lap();
    for (0..iterations) |_| {
        var r = expandFile(alloc, bmp, "bmp") catch null;
        if (r) |*res| {
            std.mem.doNotOptimizeAway(res.entries.ptr);
            res.deinit();
        }
    }
    const elapsed_ns = timer.read();
    const ns_per_op = elapsed_ns / iterations;

    std.debug.print("  BMP 64x64 expansion: {d} ns/op ({d:.2} ms/op)\n", .{
        ns_per_op,
        @as(f64, @floatFromInt(ns_per_op)) / 1e6,
    });
}

test "microbench: JPEG→JXL transcode 8x8" {
    if (builtin.mode == .Debug) return;

    const jxl_local = @import("jxl.zig");
    const alloc = testing.allocator;

    // Minimal 8x8 JPEG from test suite
    const jpeg = [_]u8{
        0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x43,
        0x00, 0x03, 0x02, 0x02, 0x02, 0x02, 0x02, 0x03, 0x02, 0x02, 0x02, 0x03,
        0x03, 0x03, 0x03, 0x04, 0x06, 0x04, 0x04, 0x04, 0x04, 0x04, 0x08, 0x06,
        0x06, 0x05, 0x06, 0x09, 0x08, 0x0a, 0x0a, 0x09, 0x08, 0x09, 0x09, 0x0a,
        0x0c, 0x0f, 0x0c, 0x0a, 0x0b, 0x0e, 0x0b, 0x09, 0x09, 0x0d, 0x11, 0x0d,
        0x0e, 0x0f, 0x10, 0x10, 0x11, 0x10, 0x0a, 0x0c, 0x12, 0x13, 0x12, 0x10,
        0x13, 0x0f, 0x10, 0x10, 0x10, 0xff, 0xdb, 0x00, 0x43, 0x01, 0x03, 0x03,
        0x03, 0x04, 0x03, 0x04, 0x08, 0x04, 0x04, 0x08, 0x10, 0x0b, 0x09, 0x0b,
        0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
        0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
        0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
        0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
        0x10, 0x10, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x00, 0x08, 0x00, 0x08, 0x03,
        0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xff, 0xc4, 0x00,
        0x14, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0xff, 0xc4, 0x00, 0x14, 0x10,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xc4, 0x00, 0x15, 0x01, 0x01, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x07, 0x09, 0xff, 0xc4, 0x00, 0x14, 0x11, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03,
        0x11, 0x00, 0x3f, 0x00, 0x3a, 0x03, 0x15, 0x4d, 0xff, 0xd9,
    };

    // Warm up
    for (0..5) |_| {
        const r = jxl_local.jpegToJxl(alloc, &jpeg) catch continue;
        alloc.free(r);
    }

    const iterations: u64 = 100;
    var timer = try std.time.Timer.start();
    _ = timer.lap();
    for (0..iterations) |_| {
        const r = jxl_local.jpegToJxl(alloc, &jpeg) catch continue;
        std.mem.doNotOptimizeAway(r.ptr);
        alloc.free(r);
    }
    const elapsed_ns = timer.read();
    const ns_per_op = elapsed_ns / iterations;

    std.debug.print("  JPEG→JXL 8x8: {d} ns/op ({d:.2} ms/op)\n", .{
        ns_per_op,
        @as(f64, @floatFromInt(ns_per_op)) / 1e6,
    });
}

test "microbench: serializeFileEntry 4KB" {
    if (builtin.mode == .Debug) return;

    const alloc = testing.allocator;
    const mini = @import("mini_blar.zig");

    const content = "The quick brown fox jumps over the lazy dog. " ** 90; // ~4KB
    const file = mini.FileEntry{
        .path = "benchmark/test.txt",
        .content = content,
    };

    // Warm up
    for (0..10) |_| {
        var to_free: std.ArrayList([]u8) = .{};
        defer { for (to_free.items) |item| alloc.free(item); to_free.deinit(alloc); }
        const r = try mini.serializeFileEntry(alloc, file, &to_free, null, null, null);
        std.mem.doNotOptimizeAway(r.ptr);
    }

    const iterations: u64 = 1000;
    var timer = try std.time.Timer.start();
    _ = timer.lap();
    for (0..iterations) |_| {
        var to_free: std.ArrayList([]u8) = .{};
        defer { for (to_free.items) |item| alloc.free(item); to_free.deinit(alloc); }
        const r = try mini.serializeFileEntry(alloc, file, &to_free, null, null, null);
        std.mem.doNotOptimizeAway(r.ptr);
    }
    const elapsed_ns = timer.read();
    const ns_per_op = elapsed_ns / iterations;

    std.debug.print("  serializeFileEntry 4KB: {d} ns/op ({d:.2} µs/op)\n", .{
        ns_per_op,
        @as(f64, @floatFromInt(ns_per_op)) / 1e3,
    });
}
