//! Educational Parser for Image Metadata (JPEG, PNG, GIF, BMP).
//!
//! This module demonstrates:
//! 1. Binary parsing of various image container structures.
//! 2. Parsing Big-Endian (JPEG, PNG) vs. Little-Endian (GIF, BMP) integer encodings.
//! 3. Bitwise shifting and type casting (`@as`, `@bitCast`).
//! 4. Memory-buffered parsing vs. incremental streaming parsing (JPEG).

const std = @import("std");
const Dir = std.Io.Dir;

/// Magic bytes (file signatures) used to identify image formats.
pub const jpegMagic: [2]u8 = .{ 0xff, 0xd8 };
pub const pngMagic: [8]u8 = .{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };
pub const gifMagic: [4]u8 = .{ 'G', 'I', 'F', '8' }; // "GIF8"
pub const bmpMagic: [2]u8 = .{ 'B', 'M' };

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

/// Streaming parser for JPEG files.
///
/// Unlike PNG/GIF/BMP which keep metadata at fixed, low offsets, JPEG metadata (SOF)
/// can be pushed far down the file by EXIF headers, ICC profiles, or thumbnail data.
/// Loading the entire image file into memory is wasteful.
///
/// Instead, this function streams the file incrementally using positional reads
/// (`std.Io.File.readPositionalAll`), traversing the segments dynamically without seeking
/// or allocating extra buffers.
fn parseJpegFile(file: anytype, io: anytype) !struct { width: u16, height: u16 } {
    const size = try std.Io.File.length(file, io);
    var offset: u64 = 2; // Skip initial SOI (Start Of Image) magic bytes (0xFFD8)

    while (offset + 4 <= size) {
        var b: [1]u8 = undefined;
        // Read marker flag (must be 0xFF)
        _ = try std.Io.File.readPositionalAll(file, io, &b, offset);
        if (b[0] != 0xff) {
            offset += 1;
            continue;
        }

        // Read marker type
        _ = try std.Io.File.readPositionalAll(file, io, &b, offset + 1);
        if (b[0] == 0xff) {
            // Consecutive 0xFFs are padding bytes in the JPEG specification
            offset += 1;
            continue;
        }

        const marker = b[0];
        if (marker == 0xd8) {
            offset += 2;
            continue;
        }
        // SOS (Start Of Scan, 0xDA) or EOI (End of Image, 0xD9) means we reached
        // the compressed image data segment without finding the SOF marker.
        if (marker == 0xd9 or marker == 0xda) {
            return error.JpegNoDimensions;
        }

        // Read segment length (2 bytes, Big-Endian)
        var len_buf: [2]u8 = undefined;
        _ = try std.Io.File.readPositionalAll(file, io, &len_buf, offset + 2);
        const segment_len = @as(u16, len_buf[0]) << 8 | len_buf[1];

        // SOF (Start of Frame) markers that contain dimensions.
        // SOF0 (0xC0) through SOF3 (0xC3) are baseline/progressive, plus other SOFs.
        const is_sof = (marker >= 0xc0 and marker <= 0xc3) or
            (marker >= 0xc5 and marker <= 0xc7) or
            (marker >= 0xc9 and marker <= 0xcb) or
            (marker >= 0xcd and marker <= 0xcf);

        if (is_sof) {
            if (offset + 9 > size) return error.JpegTooShort;
            var sof_buf: [5]u8 = undefined;
            // Read precision (1 byte), height (2 bytes), and width (2 bytes)
            _ = try std.Io.File.readPositionalAll(file, io, &sof_buf, offset + 4);
            const h = @as(u16, sof_buf[1]) << 8 | sof_buf[2];
            const w = @as(u16, sof_buf[3]) << 8 | sof_buf[4];
            return .{ .width = w, .height = h };
        }

        // Skip current segment by jumping over the marker prefix (2B) + segment length payload.
        offset += 2 + segment_len;
    }

    return error.JpegNoDimensions;
}

/// Try parsing a file as an image. Returns dimensions and format on success.
///
/// This implements an optimized two-step process:
/// 1. Reads the first 64 bytes of the file to check magic numbers (signatures).
/// 2. If it is a format with headers at fixed offsets (PNG, GIF, BMP), it parses them
///    directly from the 64-byte in-memory buffer to avoid further read calls.
/// 3. If it is a JPEG, it delegates to `parseJpegFile` to scan the segments incrementally.
pub fn parseFile(path: []const u8, io: anytype) !struct { format: []const u8, width: u32, height: u32 } {
    const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer std.Io.File.close(file, io);

    var header: [64]u8 = undefined;
    const count = try std.Io.File.readPositionalAll(file, io, &header, 0);
    const data = header[0..count];

    // Try parsing based on identified magic bytes.
    if (data.len >= 2 and data[0] == jpegMagic[0] and data[1] == jpegMagic[1]) {
        const dims = try parseJpegFile(file, io);
        return .{ .format = "jpeg", .width = @as(u32, dims.width), .height = @as(u32, dims.height) };
    } else if (data.len >= 8 and std.mem.eql(u8, data[0..8], &pngMagic)) {
        const dims = try parsePng(data);
        return .{ .format = "png", .width = dims.width, .height = dims.height };
    } else if (data.len >= 6 and std.mem.eql(u8, data[0..4], &gifMagic)) {
        const dims = try parseGif(data);
        return .{ .format = "gif", .width = @as(u32, dims.width), .height = @as(u32, dims.height) };
    } else if (data.len >= 26 and data[0] == bmpMagic[0] and data[1] == bmpMagic[1]) {
        const dims = try parseBmp(data);
        return .{ .format = "bmp", .width = dims.width, .height = dims.height };
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
