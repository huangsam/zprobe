//! Educational Parser for Image Metadata (JPEG, PNG, GIF, BMP).
//!
//! This module demonstrates:
//! 1. Binary parsing of various image container structures.
//! 2. Parsing Big-Endian (JPEG, PNG) vs. Little-Endian (GIF, BMP) integer encodings.
//! 3. Bitwise shifting and type casting (`@as`, `@bitCast`).
//! 4. Memory-buffered parsing vs. incremental streaming parsing (JPEG).

const std = @import("std");
const Dir = std.Io.Dir;
const ByteReader = @import("byte_reader.zig").ByteReader;

/// Magic bytes (file signatures) used to identify image formats.
pub const jpegMagic: [2]u8 = .{ 0xff, 0xd8 };
pub const pngMagic: [8]u8 = .{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };
pub const gifMagic: [4]u8 = .{ 'G', 'I', 'F', '8' }; // "GIF8"
pub const bmpMagic: [2]u8 = .{ 'B', 'M' };
pub const webpRiffMagic: [4]u8 = .{ 'R', 'I', 'F', 'F' };
pub const webpWebpMagic: [4]u8 = .{ 'W', 'E', 'B', 'P' };

/// Parse JPEG width and height from Start-Of-Frame (SOF) markers.
///
/// ### JPEG Binary Structure
/// JPEGs are structured as a series of **segments**. Each segment begins with marker prefix `0xFF`
/// followed by a 1-byte marker ID:
/// ```
/// +--------+------------+------------------+-----------------------+
/// |  0xFF  | Marker Tag |  Segment Length  |    Payload Data       |
/// | (1B)   |   (1B)     |   (2B, Big-End)  |  (Segment Length - 2) |
/// +--------+------------+------------------+-----------------------+
/// ```
///
/// **SOF Markers (0xC0 - 0xC3, etc.)** contain image parameters:
/// - Offset 0: Data precision (1 byte)
/// - Offset 1..2: Height (2 bytes, Big-Endian)
pub fn parseJpeg(header: []const u8) !struct { width: u16, height: u16 } {
    if (header.len < 2 or header[0] != jpegMagic[0] or header[1] != jpegMagic[1])
        return error.NotJpeg;

    // Walk JPEG segments looking for SOF markers.
    var off: usize = 2;
    while (off + 4 <= header.len) {
        if (header[off] != 0xff) {
            off += 1;
            continue;
        }

        const marker = header[off + 1];

        // Consecutive 0xFF padding bytes in the JPEG specification
        if (marker == 0xff) {
            off += 1;
            continue;
        }

        // SOF markers: 0xc0-c3 contain image dimensions.
        if (marker >= 0xc0 and marker <= 0xc3) {
            if (off + 9 > header.len) return error.JpegTooShort;
            // Decode Big-Endian 16-bit integers
            const h = @as(u16, header[off + 5]) << 8 | @as(u16, header[off + 6]);
            const w = @as(u16, header[off + 7]) << 8 | @as(u16, header[off + 8]);
            return .{ .width = w, .height = h };
        }

        // Skip over this segment.
        if (marker == 0x00 or marker == 0x01) {
            off += 2;
        } else if (marker >= 0xd0 and marker <= 0xd7) {
            off += 2;
        } else if (marker == 0xd8) {
            off += 2; // SOS - end of image data.
        } else {
            const seg_len = @as(u16, header[off + 2]) << 8 | @as(u16, header[off + 3]);
            off += 2 + seg_len;
        }

        if (off > header.len) break;
    }

    return error.JpegNoDimensions;
}

/// Parse PNG width and height from the IHDR chunk.
///
/// ### PNG Binary Structure
/// PNG files begin with an 8-byte signature, followed by a sequence of **chunks**:
/// ```
/// +-----------------+------------------+-----------------------+-----------------+
/// |  Chunk Length   |    Chunk Type    |     Chunk Payload     |       CRC       |
/// |  (4B, Big-End)  |  "IHDR", etc.    |  (Chunk Length bytes) |  (4B, Big-End)  |
/// +-----------------+------------------+-----------------------+-----------------+
/// ```
///
/// The very first chunk **MUST** be `IHDR` (Image Header), which contains dimensions:
/// - Offset 12..15: Width (4 bytes, Big-Endian)
pub fn parsePng(header: []const u8) !struct { width: u32, height: u32 } {
    if (header.len < 8 or !std.mem.eql(u8, header[0..8], &pngMagic))
        return error.NotPng;

    if (header.len < 8 + 4 + 4 + 13) return error.PngTooShort;

    const ihdr_len = @as(u32, header[8]) << 24 | @as(u32, header[9]) << 16 |
        @as(u32, header[10]) << 8 | @as(u32, header[11]);
    if (ihdr_len < 13) return error.PngTooShort;

    const type_bytes = header[12..16];
    if (!std.mem.eql(u8, type_bytes, "IHDR")) return error.PngNoIhdr;

    // Extract big-endian 32-bit width and height.
    const w = @as(u32, header[16]) << 24 | @as(u32, header[17]) << 16 |
        @as(u32, header[18]) << 8 | @as(u32, header[19]);
    const h = @as(u32, header[20]) << 24 | @as(u32, header[21]) << 16 |
        @as(u32, header[22]) << 8 | @as(u32, header[23]);

    return .{ .width = w, .height = h };
}

/// Parse GIF dimensions from the Logical Screen Descriptor.
///
/// ### GIF Binary Structure
/// GIF files start with a 6-byte signature ("GIF87a" or "GIF89a"), directly followed
/// by the **Logical Screen Descriptor**:
/// ```
/// +-----------------------+----------------------+----------------------+
/// |  Signature ("GIF8")   |     Screen Width     |    Screen Height     |
/// |     (4B Header)       | (2B, Little-Endian)  | (2B, Little-Endian)  |
/// +-----------------------+----------------------+----------------------+
/// ```
pub fn parseGif(header: []const u8) !struct { width: u16, height: u16 } {
    if (header.len < 10 or !std.mem.eql(u8, header[0..4], &gifMagic))
        return error.NotGif;

    // Decode Little-Endian 16-bit values.
    const w = @as(u16, header[6]) | (@as(u16, header[7]) << 8);
    const h = @as(u16, header[8]) | (@as(u16, header[9]) << 8);

    return .{ .width = w, .height = h };
}

/// Parse BMP dimensions from the DIB header.
///
/// ### BMP Binary Structure
/// BMP files begin with a 14-byte File Header, followed by a DIB Header (Device Independent Bitmap).
/// The DIB header width and height are located at:
/// - Offset 18..21: Width (4 bytes, signed Little-Endian)
/// - Offset 22..25: Height (4 bytes, signed Little-Endian)
///
/// **Top-Down Bitmaps:**
/// If the height is negative, the bitmap pixels are organized from top-to-bottom
/// (instead of the traditional bottom-to-top layout). We take the absolute value
/// to get the logical height.
pub fn parseBmp(header: []const u8) !struct { width: u32, height: u32 } {
    if (header.len < 26 or header[0] != bmpMagic[0] or header[1] != bmpMagic[1])
        return error.NotBmp;

    // Decode Little-Endian 32-bit unsigned/signed integers.
    const w = @as(u32, header[18]) |
        @as(u32, header[19]) << 8 |
        @as(u32, header[20]) << 16 |
        @as(u32, header[21]) << 24;

    const h_u32 = @as(u32, header[22]) |
        @as(u32, header[23]) << 8 |
        @as(u32, header[24]) << 16 |
        @as(u32, header[25]) << 24;

    // Reinterpret bit pattern to signed i32 using @bitCast.
    const h_raw = @as(i32, @bitCast(h_u32));
    const h = if (h_raw < 0) @as(u32, @intCast(-h_raw)) else h_u32;

    return .{ .width = w, .height = h };
}

/// Parse WebP dimensions from VP8, VP8L, or VP8X chunks.
///
/// ### WebP Container & Chunks Structure:
/// WebP files are RIFF containers. They begin with:
/// - Offset 0..3: "RIFF"
/// - Offset 4..7: File size (little-endian)
/// - Offset 8..11: "WEBP"
///
/// Following the 12-byte header is the first chunk:
/// - Offset 12..15: Chunk Tag ("VP8X", "VP8L", or "VP8 ")
/// - Offset 16..19: Chunk Size (4 bytes, little-endian)
///
/// **VP8X (Extended):**
/// - Payload starts at offset 20.
/// - Width - 1 is stored at offset 24..26 (24-bit little-endian)
/// - Height - 1 is stored at offset 27..29 (24-bit little-endian)
///
/// **VP8L (Lossless):**
/// - Payload starts at offset 20.
/// - Signature byte `0x2f` at offset 20.
/// - Bits 0..13 of bytes 21..24 (32-bit little-endian) are Width - 1.
/// - Bits 14..27 of bytes 21..24 are Height - 1.
///
/// **VP8 (Lossy):**
/// - Payload starts at offset 20.
/// - Byte 20 is frame tag (bit 0 must be 0 for keyframe).
/// - Bytes 23..25 must be sync code `0x9d 0x01 0x2a`.
/// - Bytes 26..27 contain horizontal scale (2 bits) and width (14 bits) (little-endian).
/// - Bytes 28..29 contain vertical scale (2 bits) and height (14 bits) (little-endian).
pub fn parseWebp(header: []const u8) !struct { width: u32, height: u32 } {
    if (header.len < 12) return error.WebpTooShort;
    if (!std.mem.eql(u8, header[0..4], &webpRiffMagic) or !std.mem.eql(u8, header[8..12], &webpWebpMagic)) {
        return error.NotWebp;
    }

    if (header.len < 20) return error.WebpTooShort;
    const chunk_tag = header[12..16];

    if (std.mem.eql(u8, chunk_tag, "VP8X")) {
        if (header.len < 30) return error.WebpTooShort;
        const w = @as(u32, header[24]) | (@as(u32, header[25]) << 8) | (@as(u32, header[26]) << 16);
        const h = @as(u32, header[27]) | (@as(u32, header[28]) << 8) | (@as(u32, header[29]) << 16);
        return .{ .width = w + 1, .height = h + 1 };
    } else if (std.mem.eql(u8, chunk_tag, "VP8L")) {
        if (header.len < 25) return error.WebpTooShort;
        if (header[20] != 0x2f) return error.InvalidWebpVP8L;
        const val = @as(u32, header[21]) |
            (@as(u32, header[22]) << 8) |
            (@as(u32, header[23]) << 16) |
            (@as(u32, header[24]) << 24);
        const w = (val & 0x3fff) + 1;
        const h = ((val >> 14) & 0x3fff) + 1;
        return .{ .width = w, .height = h };
    } else if (std.mem.eql(u8, chunk_tag, "VP8 ")) {
        if (header.len < 30) return error.WebpTooShort;
        // Check frame tag (bit 0 of byte 20 must be 0 for key frame)
        if ((header[20] & 0x01) != 0) return error.InvalidWebpVP8Keyframe;
        // Check sync code
        if (header[23] != 0x9d or header[24] != 0x01 or header[25] != 0x2a) {
            return error.InvalidWebpVP8Sync;
        }
        const w = (@as(u16, header[26]) | (@as(u16, header[27]) << 8)) & 0x3fff;
        const h = (@as(u16, header[28]) | (@as(u16, header[29]) << 8)) & 0x3fff;
        return .{ .width = w, .height = h };
    }

    return error.UnsupportedWebpChunk;
}

/// Streaming parser for JPEG files.
///
/// Unlike PNG/GIF/BMP which keep metadata at fixed, low offsets, JPEG metadata (SOF)
/// can be pushed far down the file by EXIF headers, ICC profiles, or thumbnail data.
/// Loading the entire image file into memory is wasteful.
///
/// Instead, this function streams the file incrementally using positional reads
/// (`std.Io.File.readPositionalAll`), traversing the segments dynamically without seeking
/// or allocating extra buffers.
pub const ImageMetadata = struct {
    format: []const u8,
    width: u32,
    height: u32,
    orientation: ?u16 = null,
    create_time: ?[]const u8 = null,
    camera_make: ?[]const u8 = null,
    camera_model: ?[]const u8 = null,
    gps_latitude: ?f64 = null,
    gps_longitude: ?f64 = null,

    pub fn deinit(self: *ImageMetadata, allocator: std.mem.Allocator) void {
        if (self.create_time) |s| allocator.free(s);
        if (self.camera_make) |s| allocator.free(s);
        if (self.camera_model) |s| allocator.free(s);
    }
};

fn getTypeSize(t: u16) usize {
    return switch (t) {
        1, 2, 7 => 1,
        3 => 2,
        4, 9 => 4,
        5, 10 => 8,
        else => 0,
    };
}

fn parseIfd(
    allocator: std.mem.Allocator,
    root_reader: *ByteReader,
    ifd_offset: usize,
    meta: *ImageMetadata,
    depth: usize,
) !void {
    if (depth > 4) return;
    if (ifd_offset == 0 or ifd_offset + 2 > root_reader.buffer.len) return;

    var ifd_reader = ByteReader.init(root_reader.buffer[ifd_offset..], root_reader.endian);
    const num_entries = try ifd_reader.readU16();

    var i: usize = 0;
    while (i < num_entries) : (i += 1) {
        if (ifd_reader.remaining() < 12) break;

        const entry_abs_offset = ifd_offset + 2 + i * 12;

        const tag = try ifd_reader.readU16();
        const type_id = try ifd_reader.readU16();
        const count = try ifd_reader.readU32();
        const inline_or_offset_val = try ifd_reader.readU32();

        const type_size = getTypeSize(type_id);
        if (type_size == 0) continue;
        const total_size = @as(u64, count) * type_size;

        var val_reader: ByteReader = undefined;
        if (total_size <= 4) {
            val_reader = ByteReader.init(root_reader.buffer[entry_abs_offset + 8 .. entry_abs_offset + 12], root_reader.endian);
        } else {
            if (inline_or_offset_val + total_size > root_reader.buffer.len) continue;
            val_reader = ByteReader.init(root_reader.buffer[inline_or_offset_val .. inline_or_offset_val + total_size], root_reader.endian);
        }

        switch (tag) {
            0x0112 => { // Orientation
                if (type_id == 3 and count == 1) {
                    meta.orientation = try val_reader.readU16();
                }
            },
            0x010f => { // Make
                if (type_id == 2) {
                    meta.camera_make = try val_reader.readAscii(allocator, count);
                }
            },
            0x0110 => { // Model
                if (type_id == 2) {
                    meta.camera_model = try val_reader.readAscii(allocator, count);
                }
            },
            0x8769 => { // Exif IFD Offset
                if (type_id == 4 and count == 1) {
                    try parseIfd(allocator, root_reader, @as(usize, inline_or_offset_val), meta, depth + 1);
                }
            },
            0x8825 => { // GPS Info IFD Offset
                if (type_id == 4 and count == 1) {
                    try parseGpsIfd(root_reader, @as(usize, inline_or_offset_val), meta);
                }
            },
            0x9003 => { // DateTimeOriginal
                if (type_id == 2) {
                    meta.create_time = try val_reader.readAscii(allocator, count);
                }
            },
            else => {},
        }
    }
}

fn parseGpsIfd(
    root_reader: *ByteReader,
    ifd_offset: usize,
    meta: *ImageMetadata,
) !void {
    if (ifd_offset == 0 or ifd_offset + 2 > root_reader.buffer.len) return;

    var gps_reader = ByteReader.init(root_reader.buffer[ifd_offset..], root_reader.endian);
    const num_entries = try gps_reader.readU16();

    var lat_ref: ?u8 = null;
    var lat_val: ?f64 = null;
    var lon_ref: ?u8 = null;
    var lon_val: ?f64 = null;

    var i: usize = 0;
    while (i < num_entries) : (i += 1) {
        if (gps_reader.remaining() < 12) break;

        const entry_abs_offset = ifd_offset + 2 + i * 12;

        const tag = try gps_reader.readU16();
        const type_id = try gps_reader.readU16();
        const count = try gps_reader.readU32();
        const inline_or_offset_val = try gps_reader.readU32();

        const type_size = getTypeSize(type_id);
        if (type_size == 0) continue;
        const total_size = @as(u64, count) * type_size;

        var val_reader: ByteReader = undefined;
        if (total_size <= 4) {
            val_reader = ByteReader.init(root_reader.buffer[entry_abs_offset + 8 .. entry_abs_offset + 12], root_reader.endian);
        } else {
            if (inline_or_offset_val + total_size > root_reader.buffer.len) continue;
            val_reader = ByteReader.init(root_reader.buffer[inline_or_offset_val .. inline_or_offset_val + total_size], root_reader.endian);
        }

        switch (tag) {
            1 => { // GPSLatitudeRef
                if (type_id == 2 and count >= 2) {
                    lat_ref = try val_reader.readU8();
                }
            },
            2 => { // GPSLatitude
                if (type_id == 5 and count == 3) {
                    const deg = try val_reader.readRational();
                    const min = try val_reader.readRational();
                    const sec = try val_reader.readRational();
                    lat_val = deg + min / 60.0 + sec / 3600.0;
                }
            },
            3 => { // GPSLongitudeRef
                if (type_id == 2 and count >= 2) {
                    lon_ref = try val_reader.readU8();
                }
            },
            4 => { // GPSLongitude
                if (type_id == 5 and count == 3) {
                    const deg = try val_reader.readRational();
                    const min = try val_reader.readRational();
                    const sec = try val_reader.readRational();
                    lon_val = deg + min / 60.0 + sec / 3600.0;
                }
            },
            else => {},
        }
    }

    if (lat_val) |lat| {
        var val = lat;
        if (lat_ref) |ref| {
            if (ref == 'S' or ref == 's') {
                val = -val;
            }
        }
        meta.gps_latitude = val;
    }
    if (lon_val) |lon| {
        var val = lon;
        if (lon_ref) |ref| {
            if (ref == 'W' or ref == 'w') {
                val = -val;
            }
        }
        meta.gps_longitude = val;
    }
}

fn parseTiff(
    allocator: std.mem.Allocator,
    tiff_buf: []const u8,
    meta: *ImageMetadata,
) !void {
    if (tiff_buf.len < 8) return error.TiffTooShort;

    var endian: std.builtin.Endian = .little;
    if (std.mem.eql(u8, tiff_buf[0..2], "II")) {
        endian = .little;
    } else if (std.mem.eql(u8, tiff_buf[0..2], "MM")) {
        endian = .big;
    } else {
        return error.InvalidTiffHeader;
    }

    var reader = ByteReader.init(tiff_buf, endian);
    try reader.skip(2); // Skip II/MM

    const magic = try reader.readU16();
    if (magic != 42) return error.InvalidTiffMagic;

    const first_ifd_offset = try reader.readU32();
    try parseIfd(allocator, &reader, @as(usize, first_ifd_offset), meta, 0);
}

fn parseJpegFile(allocator: std.mem.Allocator, reader: *std.Io.Reader, meta: *ImageMetadata) !struct { width: u16, height: u16 } {
    // Skip initial SOI (Start Of Image) magic bytes (0xFFD8)
    try reader.discardAll(2);

    while (true) {
        const marker_bytes = reader.peek(2) catch |err| {
            if (err == error.EndOfStream) return error.JpegNoDimensions;
            return err;
        };

        if (marker_bytes[0] != 0xff) {
            reader.toss(1);
            continue;
        }

        if (marker_bytes[1] == 0xff) {
            // Consecutive 0xFFs are padding bytes in the JPEG specification
            reader.toss(1);
            continue;
        }

        const marker = marker_bytes[1];
        reader.toss(2);

        if (marker == 0xd8) {
            continue;
        }
        // SOS (Start Of Scan, 0xDA) or EOI (End of Image, 0xD9) means we reached
        // the compressed image data segment without finding the SOF marker.
        if (marker == 0xd9 or marker == 0xda) {
            return error.JpegNoDimensions;
        }

        // Read segment length (2 bytes, Big-Endian)
        const len_bytes = reader.peek(2) catch |err| {
            if (err == error.EndOfStream) return error.JpegTooShort;
            return err;
        };
        const segment_len = @as(u16, len_bytes[0]) << 8 | len_bytes[1];
        reader.toss(2);

        if (segment_len < 2) return error.InvalidJpeg;

        // Parse EXIF APP1
        if (marker == 0xe1) {
            const payload_len = segment_len - 2;
            if (payload_len >= 6) {
                const app1_buf = try allocator.alloc(u8, payload_len);
                defer allocator.free(app1_buf);
                try reader.readSliceAll(app1_buf);

                if (std.mem.startsWith(u8, app1_buf, "Exif\x00\x00")) {
                    parseTiff(allocator, app1_buf[6..], meta) catch {};
                }
            } else {
                try reader.discardAll(payload_len);
            }
            continue;
        }

        // SOF (Start of Frame) markers that contain dimensions.
        const is_sof = (marker >= 0xc0 and marker <= 0xc3) or
            (marker >= 0xc5 and marker <= 0xc7) or
            (marker >= 0xc9 and marker <= 0xcb) or
            (marker >= 0xcd and marker <= 0xcf);

        if (is_sof) {
            const sof_bytes = reader.peek(5) catch |err| {
                if (err == error.EndOfStream) return error.JpegTooShort;
                return err;
            };
            const h = @as(u16, sof_bytes[1]) << 8 | sof_bytes[2];
            const w = @as(u16, sof_bytes[3]) << 8 | sof_bytes[4];
            return .{ .width = w, .height = h };
        }

        // Skip current segment payload
        try reader.discardAll(segment_len - 2);
    }
}

fn parseWebpFile(allocator: std.mem.Allocator, file: anytype, io: anytype, meta: *ImageMetadata) !void {
    const size = try std.Io.File.length(file, io);
    if (size < 12) return error.WebpTooShort;

    var header: [12]u8 = undefined;
    _ = try std.Io.File.readPositionalAll(file, io, &header, 0);
    if (!std.mem.eql(u8, header[0..4], &webpRiffMagic) or !std.mem.eql(u8, header[8..12], &webpWebpMagic)) {
        return error.NotWebp;
    }

    var offset: u64 = 12;
    var dims_found = false;

    while (offset + 8 <= size) {
        var chunk_header: [8]u8 = undefined;
        _ = try std.Io.File.readPositionalAll(file, io, &chunk_header, offset);

        const chunk_tag = chunk_header[0..4];
        const chunk_size = @as(u64, chunk_header[4]) |
            @as(u64, chunk_header[5]) << 8 |
            @as(u64, chunk_header[6]) << 16 |
            @as(u64, chunk_header[7]) << 24;

        const real_size = chunk_size + (chunk_size & 1);

        if (offset + 8 + real_size > size) return error.WebpTooShort;

        if (std.mem.eql(u8, chunk_tag, "VP8X")) {
            var payload: [10]u8 = undefined;
            _ = try std.Io.File.readPositionalAll(file, io, &payload, offset + 8);
            meta.width = (@as(u32, payload[4]) | (@as(u32, payload[5]) << 8) | (@as(u32, payload[6]) << 16)) + 1;
            meta.height = (@as(u32, payload[7]) | (@as(u32, payload[8]) << 8) | (@as(u32, payload[9]) << 16)) + 1;
            dims_found = true;
        } else if (std.mem.eql(u8, chunk_tag, "VP8L")) {
            var payload: [5]u8 = undefined;
            _ = try std.Io.File.readPositionalAll(file, io, &payload, offset + 8);
            if (payload[0] == 0x2f) {
                const val = @as(u32, payload[1]) | (@as(u32, payload[2]) << 8) | (@as(u32, payload[3]) << 16) | (@as(u32, payload[4]) << 24);
                meta.width = (val & 0x3fff) + 1;
                meta.height = ((val >> 14) & 0x3fff) + 1;
                dims_found = true;
            }
        } else if (std.mem.eql(u8, chunk_tag, "VP8 ")) {
            var payload: [10]u8 = undefined;
            _ = try std.Io.File.readPositionalAll(file, io, &payload, offset + 8);
            if ((payload[0] & 0x01) == 0 and payload[3] == 0x9d and payload[4] == 0x01 and payload[5] == 0x2a) {
                meta.width = (@as(u16, payload[6]) | (@as(u16, payload[7]) << 8)) & 0x3fff;
                meta.height = (@as(u16, payload[8]) | (@as(u16, payload[9]) << 8)) & 0x3fff;
                dims_found = true;
            }
        } else if (std.mem.eql(u8, chunk_tag, "EXIF")) {
            const exif_buf = try allocator.alloc(u8, chunk_size);
            defer allocator.free(exif_buf);
            _ = try std.Io.File.readPositionalAll(file, io, exif_buf, offset + 8);
            parseTiff(allocator, exif_buf, meta) catch {};
        }

        offset += 8 + real_size;
    }

    if (!dims_found) return error.WebpNoDimensions;
}

fn parsePngFile(allocator: std.mem.Allocator, file: anytype, io: anytype, meta: *ImageMetadata) !void {
    const size = try std.Io.File.length(file, io);
    if (size < 8) return error.PngTooShort;

    var sig: [8]u8 = undefined;
    _ = try std.Io.File.readPositionalAll(file, io, &sig, 0);
    if (!std.mem.eql(u8, &sig, &pngMagic)) return error.NotPng;

    var offset: u64 = 8;
    var dims_found = false;

    while (offset + 12 <= size) {
        var chunk_header: [8]u8 = undefined;
        _ = try std.Io.File.readPositionalAll(file, io, &chunk_header, offset);

        const chunk_len = @as(u32, chunk_header[0]) << 24 |
            @as(u32, chunk_header[1]) << 16 |
            @as(u32, chunk_header[2]) << 8 |
            @as(u32, chunk_header[3]);

        const chunk_tag = chunk_header[4..8];

        if (std.mem.eql(u8, chunk_tag, "IHDR")) {
            if (chunk_len < 13 or offset + 8 + 13 > size) return error.PngTooShort;
            var payload: [8]u8 = undefined;
            _ = try std.Io.File.readPositionalAll(file, io, &payload, offset + 8);
            meta.width = @as(u32, payload[0]) << 24 | @as(u32, payload[1]) << 16 | @as(u32, payload[2]) << 8 | payload[3];
            meta.height = @as(u32, payload[4]) << 24 | @as(u32, payload[5]) << 16 | @as(u32, payload[6]) << 8 | payload[7];
            dims_found = true;
        } else if (std.mem.eql(u8, chunk_tag, "eXIf")) {
            if (offset + 8 + chunk_len > size) return error.PngTooShort;
            const exif_buf = try allocator.alloc(u8, chunk_len);
            defer allocator.free(exif_buf);
            _ = try std.Io.File.readPositionalAll(file, io, exif_buf, offset + 8);
            parseTiff(allocator, exif_buf, meta) catch {};
        }

        offset += 12 + chunk_len;
    }

    if (!dims_found) return error.PngNoIhdr;
}

/// Try parsing a file as an image. Returns dimensions and format on success.
///
/// This implements an optimized two-step process:
/// 1. Reads the first 64 bytes of the file to check magic numbers (signatures).
/// 2. If it is a format with headers at fixed offsets (PNG, GIF, BMP), it parses them
///    directly from the 64-byte in-memory buffer to avoid further read calls.
/// 3. If it is a JPEG, it delegates to `parseJpegFile` to scan the segments incrementally.
pub fn parseFile(allocator: std.mem.Allocator, path: []const u8, io: anytype) !ImageMetadata {
    const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer std.Io.File.close(file, io);

    var header: [64]u8 = undefined;
    const count = try std.Io.File.readPositionalAll(file, io, &header, 0);
    const data = header[0..count];

    var meta = ImageMetadata{
        .format = "unknown",
        .width = 0,
        .height = 0,
    };

    // Try parsing based on identified magic bytes.
    if (data.len >= 2 and data[0] == jpegMagic[0] and data[1] == jpegMagic[1]) {
        meta.format = "jpeg";
        var read_buf: [1024]u8 = undefined;
        var f_reader = std.Io.File.reader(file, io, &read_buf);
        const reader = &f_reader.interface;
        const dims = try parseJpegFile(allocator, reader, &meta);
        meta.width = dims.width;
        meta.height = dims.height;
        return meta;
    } else if (data.len >= 8 and std.mem.eql(u8, data[0..8], &pngMagic)) {
        meta.format = "png";
        try parsePngFile(allocator, file, io, &meta);
        return meta;
    } else if (data.len >= 6 and std.mem.eql(u8, data[0..4], &gifMagic)) {
        meta.format = "gif";
        const dims = try parseGif(data);
        meta.width = dims.width;
        meta.height = dims.height;
        return meta;
    } else if (data.len >= 26 and data[0] == bmpMagic[0] and data[1] == bmpMagic[1]) {
        meta.format = "bmp";
        const dims = try parseBmp(data);
        meta.width = dims.width;
        meta.height = dims.height;
        return meta;
    } else if (data.len >= 12 and std.mem.eql(u8, data[0..4], &webpRiffMagic) and std.mem.eql(u8, data[8..12], &webpWebpMagic)) {
        meta.format = "webp";
        try parseWebpFile(allocator, file, io, &meta);
        return meta;
    }

    return error.NotImage;
}

test "parse gif header" {
    const header = "\x47\x49\x46\x38\x39\x61\x40\x01\xf0\x00";
    const dims = try parseGif(header);
    try std.testing.expectEqual(@as(u16, 320), dims.width);
    try std.testing.expectEqual(@as(u16, 240), dims.height);
}

test "parse png header" {
    const header = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0dIHDR\x00\x00\x02\x80\x00\x00\x01\xe0\x08\x02\x00\x00\x00";
    const dims = try parsePng(header);
    try std.testing.expectEqual(@as(u32, 640), dims.width);
    try std.testing.expectEqual(@as(u32, 480), dims.height);
}

test "parse jpeg header" {
    const header = "\xff\xd8\xff\xc0\x00\x0b\x08\x00\xf0\x01\x40\x03";
    const dims = try parseJpeg(header);
    try std.testing.expectEqual(@as(u16, 320), dims.width);
    try std.testing.expectEqual(@as(u16, 240), dims.height);
}

test "parse bmp header" {
    const header = "BM\x36\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x28\x00\x00\x00\x40\x01\x00\x00\xf0\x00\x00\x00";
    const dims = try parseBmp(header);
    try std.testing.expectEqual(@as(u32, 320), dims.width);
    try std.testing.expectEqual(@as(u32, 240), dims.height);
}

test "parse png header: too short returns error" {
    const header = "\x89\x50\x4e\x47";
    const result = parsePng(header);
    try std.testing.expectEqual(error.NotPng, result);
}

test "parse png header: wrong IHDR type" {
    const header = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0dXXXX\x00\x00\x02\x80\x00\x00\x01\xe0\x08\x02\x00\x00\x00";
    const result = parsePng(header);
    try std.testing.expectEqual(error.PngNoIhdr, result);
}

test "parse png header: truncated IHDR chunk" {
    const header = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0a";
    const result = parsePng(header);
    try std.testing.expectError(error.PngTooShort, result);
}

test "parse gif header: too short returns error" {
    const header = "\x47\x49\x46\x38";
    const result = parseGif(header);
    try std.testing.expectEqual(error.NotGif, result);
}

test "parse gif header: truncated dimensions" {
    const header = "\x47\x49\x46\x38\x39\x61\x40";
    const result = parseGif(header);
    try std.testing.expectError(error.NotGif, result);
}

test "parse bmp header: too short returns error" {
    const header = "BM\x00";
    const result = parseBmp(header);
    try std.testing.expectEqual(error.NotBmp, result);
}

test "parse bmp header: wrong magic bytes" {
    const header = "XX\x36\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x28\x00\x00\x00\x40\x01\x00\x00\xf0\x00\x00\x00";
    const result = parseBmp(header);
    try std.testing.expectEqual(error.NotBmp, result);
}

test "parse jpeg header: no SOF marker returns error" {
    const header = "\xff\xd8\xff\xdb\xff\xd9";
    const result = parseJpeg(header);
    try std.testing.expectError(error.JpegNoDimensions, result);
}

test "parse jpeg header: too short for JPEG detection" {
    const header = "\xff\xd8";
    const result = parseJpeg(header);
    try std.testing.expectError(error.JpegNoDimensions, result);
}

test "parse jpeg header: single byte returns error" {
    const header = "\xff";
    const result = parseJpeg(header);
    try std.testing.expectEqual(error.NotJpeg, result);
}

test "parse jpeg header: SOI only returns error" {
    const header = "\xff\xd8\xff\x00\xff\xd9";
    const result = parseJpeg(header);
    try std.testing.expectError(error.JpegNoDimensions, result);
}

test "parse jpeg header: marker 0x00 skipped correctly" {
    // JPEG with a 0x00 marker (UNDEFINED)
    const header = "\xff\xd8\xff\x00\xff\xc0\x00\x0b\x08\x00\xf0\x01\x40\x03";
    const dims = try parseJpeg(header);
    try std.testing.expectEqual(@as(u16, 320), dims.width);
    try std.testing.expectEqual(@as(u16, 240), dims.height);
}

test "parse jpeg header: consecutive 0xff padding bytes" {
    const header = "\xff\xd8\xff\xff\xff\xff\xff\xc0\x00\x0b\x08\x00\xf0\x01\x40\x03";
    const dims = try parseJpeg(header);
    try std.testing.expectEqual(@as(u16, 320), dims.width);
    try std.testing.expectEqual(@as(u16, 240), dims.height);
}

test "parse jpeg header: SOS marker without SOF returns error" {
    const header = "\xff\xd8\xff\xda\xff\x00\x00\x00\xff\xd9";
    const result = parseJpeg(header);
    try std.testing.expectError(error.JpegNoDimensions, result);
}

test "parse jpeg header: EOI marker without SOF returns error" {
    const header = "\xff\xd8\xff\xe0\x00\x10\x4a\x46\x49\x46\x00\x01\xff\xd9";
    const result = parseJpeg(header);
    try std.testing.expectError(error.JpegNoDimensions, result);
}

test "parse jpeg header: SOF1 (0xc1) also works" {
    // SOF1 marker with dimensions 1920x1080 (height 1080 = 0x0438, width 1920 = 0x0780)
    const header = "\xff\xd8\xff\xc1\x00\x0c\x08\x04\x38\x07\x80\x03";
    const dims = try parseJpeg(header);
    try std.testing.expectEqual(@as(u16, 1920), dims.width);
    try std.testing.expectEqual(@as(u16, 1080), dims.height);
}

test "parse jpeg header: SOF3 (0xc3) also works" {
    // SOF3 marker with dimensions 800x600 (height 600 = 0x0258, width 800 = 0x0320)
    const header = "\xff\xd8\xff\xc3\x00\x0b\x08\x02\x58\x03\x20\x03";
    const dims = try parseJpeg(header);
    try std.testing.expectEqual(@as(u16, 800), dims.width);
    try std.testing.expectEqual(@as(u16, 600), dims.height);
}

test "parse jpeg header: segment length zero" {
    // JPEG with a segment of length 0 (valid but unusual)
    const header = "\xff\xd8\xff\x00\xff\xc0\x00\x0b\x08\x00\xf0\x01\x40\x03";
    const dims = try parseJpeg(header);
    try std.testing.expectEqual(@as(u16, 320), dims.width);
    try std.testing.expectEqual(@as(u16, 240), dims.height);
}

test "parse jpeg header: truncated segment returns error" {
    // SOF marker but not enough bytes for dimensions
    const header = "\xff\xd8\xff\xc0\x00\x05\x08";
    const result = parseJpeg(header);
    try std.testing.expectError(error.JpegTooShort, result);
}

test "parse jpeg header: no SOF in multiple segments" {
    // JPEG with APP0 and APP1 but no SOF
    const header = "\xff\xd8\xff\xe0\x00\x10\x4a\x46\x49\x46\x00\x01\x00\x00\x01\x00\x00\xff\xd8\xff\xd9";
    const result = parseJpeg(header);
    try std.testing.expectError(error.JpegNoDimensions, result);
}

test "parse WebP: VP8X extended header" {
    // Width 1000 (999 = 0x03e7 -> e7 03 00), Height 800 (799 = 0x031f -> 1f 03 00)
    const header = "RIFF\x00\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x00\x00\x00\x00\xe7\x03\x00\x1f\x03\x00";
    const dims = try parseWebp(header);
    try std.testing.expectEqual(@as(u32, 1000), dims.width);
    try std.testing.expectEqual(@as(u32, 800), dims.height);
}

test "parse WebP: VP8L lossless header" {
    // Width 1000 (999 = 0x03e7), Height 800 (799 = 0x031f)
    // val = 999 | (799 << 14) = 0x00c7c3e7 -> e7 c3 c7 00
    const header = "RIFF\x00\x00\x00\x00WEBPVP8L\x00\x00\x00\x00\x2f\xe7\xc3\xc7\x00";
    const dims = try parseWebp(header);
    try std.testing.expectEqual(@as(u32, 1000), dims.width);
    try std.testing.expectEqual(@as(u32, 800), dims.height);
}

test "parse WebP: VP8 lossy header" {
    // Width 1000 (0x03e8 -> e8 03), Height 800 (0x0320 -> 20 03)
    const header = "RIFF\x00\x00\x00\x00WEBPVP8 \x00\x00\x00\x00\x00\x00\x00\x9d\x01\x2a\xe8\x03\x20\x03";
    const dims = try parseWebp(header);
    try std.testing.expectEqual(@as(u32, 1000), dims.width);
    try std.testing.expectEqual(@as(u32, 800), dims.height);
}

test "parse WebP: invalid signature returns error" {
    const header = "RIFF\x00\x00\x00\x00XXXXVP8X\x0a\x00\x00\x00\x00\x00\x00\x00\xe7\x03\x00\x1f\x03\x00";
    const result = parseWebp(header);
    try std.testing.expectError(error.NotWebp, result);
}

test "parse WebP: too short returns error" {
    const header = "RIFF\x00\x00\x00\x00WEBP";
    const result = parseWebp(header);
    try std.testing.expectError(error.WebpTooShort, result);
}

test "parse WebP: VP8L invalid signature byte" {
    const header = "RIFF\x00\x00\x00\x00WEBPVP8L\x00\x00\x00\x00\xff\xe7\xc3\xc7\x00";
    const result = parseWebp(header);
    try std.testing.expectError(error.InvalidWebpVP8L, result);
}

test "parse WebP: VP8 wrong sync code" {
    const header = "RIFF\x00\x00\x00\x00WEBPVP8 \x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xe8\x03\x20\x03";
    const result = parseWebp(header);
    try std.testing.expectError(error.InvalidWebpVP8Sync, result);
}

test "parse WebP: VP8 not keyframe" {
    // byte 20 has bit 0 set to 1 (interframe)
    const header = "RIFF\x00\x00\x00\x00WEBPVP8 \x00\x00\x00\x00\x01\x00\x00\x9d\x01\x2a\xe8\x03\x20\x03";
    const result = parseWebp(header);
    try std.testing.expectError(error.InvalidWebpVP8Keyframe, result);
}

test "parseTiff EXIF and GPS tags" {
    const allocator = std.testing.allocator;
    var meta = ImageMetadata{
        .format = "jpeg",
        .width = 100,
        .height = 100,
    };
    defer meta.deinit(allocator);

    var buf = [_]u8{0} ** 200;
    // TIFF Header
    buf[0] = 'I';
    buf[1] = 'I';
    buf[2] = 42;
    buf[3] = 0;
    buf[4] = 8;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 0;

    // First IFD (offset 8)
    buf[8] = 4;
    buf[9] = 0; // 4 entries

    // Entry 1: Orientation (tag 0x0112)
    buf[10] = 0x12;
    buf[11] = 0x01; // Tag
    buf[12] = 3;
    buf[13] = 0; // SHORT
    buf[14] = 1;
    buf[15] = 0;
    buf[16] = 0;
    buf[17] = 0; // count = 1
    buf[18] = 6;
    buf[19] = 0;
    buf[20] = 0;
    buf[21] = 0; // value = 6

    // Entry 2: Make (tag 0x010f)
    buf[22] = 0x0f;
    buf[23] = 0x01; // Tag
    buf[24] = 2;
    buf[25] = 0; // ASCII
    buf[26] = 5;
    buf[27] = 0;
    buf[28] = 0;
    buf[29] = 0; // count = 5
    buf[30] = 62;
    buf[31] = 0;
    buf[32] = 0;
    buf[33] = 0; // offset = 62

    // Entry 3: Model (tag 0x0110)
    buf[34] = 0x10;
    buf[35] = 0x01; // Tag
    buf[36] = 2;
    buf[37] = 0; // ASCII
    buf[38] = 4;
    buf[39] = 0;
    buf[40] = 0;
    buf[41] = 0; // count = 4
    buf[42] = 'A';
    buf[43] = '7';
    buf[44] = 'C';
    buf[45] = 0; // inline value

    // Entry 4: GPS IFD (tag 0x8825)
    buf[46] = 0x25;
    buf[47] = 0x88; // Tag
    buf[48] = 4;
    buf[49] = 0; // LONG
    buf[50] = 1;
    buf[51] = 0;
    buf[52] = 0;
    buf[53] = 0; // count = 1
    buf[54] = 72;
    buf[55] = 0;
    buf[56] = 0;
    buf[57] = 0; // offset = 72

    // next IFD offset (0) -> buf[58..61]

    // ASCII strings
    @memcpy(buf[62..67], "Sony\x00");

    // GPS IFD (offset 72)
    buf[72] = 4;
    buf[73] = 0; // 4 entries

    // GPSLatitudeRef (tag 0x0001)
    buf[74] = 1;
    buf[75] = 0;
    buf[76] = 2;
    buf[77] = 0; // ASCII
    buf[78] = 2;
    buf[79] = 0;
    buf[80] = 0;
    buf[81] = 0; // count = 2
    buf[82] = 'N';
    buf[83] = 0;
    buf[84] = 0;
    buf[85] = 0;

    // GPSLatitude (tag 0x0002)
    buf[86] = 2;
    buf[87] = 0;
    buf[88] = 5;
    buf[89] = 0; // RATIONAL
    buf[90] = 3;
    buf[91] = 0;
    buf[92] = 0;
    buf[93] = 0; // count = 3
    buf[94] = 124;
    buf[95] = 0;
    buf[96] = 0;
    buf[97] = 0; // offset = 124

    // GPSLongitudeRef (tag 0x0003)
    buf[98] = 3;
    buf[99] = 0;
    buf[100] = 2;
    buf[101] = 0; // ASCII
    buf[102] = 2;
    buf[103] = 0;
    buf[104] = 0;
    buf[105] = 0; // count = 2
    buf[106] = 'W';
    buf[107] = 0;
    buf[108] = 0;
    buf[109] = 0;

    // GPSLongitude (tag 0x0004)
    buf[110] = 4;
    buf[111] = 0;
    buf[112] = 5;
    buf[113] = 0; // RATIONAL
    buf[114] = 3;
    buf[115] = 0;
    buf[116] = 0;
    buf[117] = 0; // count = 3
    buf[118] = 148;
    buf[119] = 0;
    buf[120] = 0;
    buf[121] = 0; // offset = 148

    // next IFD offset (0) -> buf[122..125]

    // GPSLatitude rationals: 37/1, 45/1, 3000/100 (30.00)
    buf[124] = 0x25;
    buf[125] = 0;
    buf[126] = 0;
    buf[127] = 0;
    buf[128] = 1;
    buf[129] = 0;
    buf[130] = 0;
    buf[131] = 0;
    buf[132] = 0x2d;
    buf[133] = 0;
    buf[134] = 0;
    buf[135] = 0;
    buf[136] = 1;
    buf[137] = 0;
    buf[138] = 0;
    buf[139] = 0;
    buf[140] = 0xb8;
    buf[141] = 0x0b;
    buf[142] = 0;
    buf[143] = 0;
    buf[144] = 0x64;
    buf[145] = 0;
    buf[146] = 0;
    buf[147] = 0;

    // GPSLongitude rationals: 122/1, 0/1, 0/1
    buf[148] = 0x7a;
    buf[149] = 0;
    buf[150] = 0;
    buf[151] = 0;
    buf[152] = 1;
    buf[153] = 0;
    buf[154] = 0;
    buf[155] = 0;
    buf[156] = 0;
    buf[157] = 0;
    buf[158] = 0;
    buf[159] = 0;
    buf[160] = 1;
    buf[161] = 0;
    buf[162] = 0;
    buf[163] = 0;
    buf[164] = 0;
    buf[165] = 0;
    buf[166] = 0;
    buf[167] = 0;
    buf[168] = 1;
    buf[169] = 0;
    buf[170] = 0;
    buf[171] = 0;

    try parseTiff(allocator, &buf, &meta);

    try std.testing.expectEqual(@as(u16, 6), meta.orientation.?);
    try std.testing.expectEqualStrings("Sony", meta.camera_make.?);
    try std.testing.expectEqualStrings("A7C", meta.camera_model.?);
    try std.testing.expect(meta.gps_latitude.? > 37.7583 and meta.gps_latitude.? < 37.7584);
    try std.testing.expectEqual(@as(f64, -122.0), meta.gps_longitude.?);
}
