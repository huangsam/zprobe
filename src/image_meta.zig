//! Parse JPEG, PNG, and GIF headers to extract dimensions.
const std = @import("std");
const Dir = std.Io.Dir;

/// Magic bytes for supported formats.
pub const jpegMagic: [2]u8 = .{ 0xff, 0xd8 };
pub const pngMagic: [8]u8 = .{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };
pub const gifMagic: [4]u8 = .{ 0x47, 0x49, 0x46, 0x38 }; // "GIF8"
pub const bmpMagic: [2]u8 = .{ 'B', 'M' };

/// Read the first N bytes from a file. Returns count of bytes read.
fn readFileHeader(header: []u8, path: []const u8, io: anytype) !usize {
    const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer std.Io.File.close(file, io);

    return try std.Io.File.readPositionalAll(
        file,
        io,
        header,
        0,
    );
}

/// Parse JPEG width and height from Start-Of-Frame markers.
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

        // SOF markers: 0xc0-c3 contain image dimensions.
        if (marker >= 0xc0 and marker <= 0xc3) {
            if (off + 8 > header.len) return error.JpegTooShort;
            const h = @as(u16, header[off + 4]) << 8 | @as(u16, header[off + 5]);
            const w = @as(u16, header[off + 6]) << 8 | @as(u16, header[off + 7]);
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
pub fn parsePng(header: []const u8) !struct { width: u32, height: u32 } {
    if (header.len < 8 or !std.mem.eql(u8, header[0..8], &pngMagic))
        return error.NotPng;

    const ihdr_len = @as(u32, header[0]) << 24 | @as(u32, header[1]) << 16 |
        @as(u32, header[2]) << 8 | @as(u32, header[3]);
    if (ihdr_len < 13 or header.len < 8 + 4 + 13) return error.PngTooShort;

    const type_bytes = header[8..12];
    if (!std.mem.eql(u8, type_bytes, "IHDR")) return error.PngNoIhdr;

    const w = @as(u32, header[12]) << 24 | @as(u32, header[13]) << 16 |
        @as(u32, header[14]) << 8 | @as(u32, header[15]);
    const h = @as(u32, header[16]) << 24 | @as(u32, header[17]) << 16 |
        @as(u32, header[18]) << 8 | @as(u32, header[19]);

    return .{ .width = w, .height = h };
}

/// Parse GIF dimensions from the Logical Screen Descriptor.
pub fn parseGif(header: []const u8) !struct { width: u16, height: u16 } {
    if (header.len < 10 or !std.mem.eql(u8, header[0..4], &gifMagic))
        return error.NotGif;

    const w = @as(u16, header[6]) | (@as(u16, header[7]) << 8);
    const h = @as(u16, header[8]) | (@as(u16, header[9]) << 8);

    return .{ .width = w, .height = h };
}

pub fn parseBmp(header: []const u8) !struct { width: u32, height: u32 } {
    if (header.len < 26 or header[0] != bmpMagic[0] or header[1] != bmpMagic[1])
        return error.NotBmp;

    const w = @as(u32, header[18]) |
        @as(u32, header[19]) << 8 |
        @as(u32, header[20]) << 16 |
        @as(u32, header[21]) << 24;

    const h_u32 = @as(u32, header[22]) |
        @as(u32, header[23]) << 8 |
        @as(u32, header[24]) << 16 |
        @as(u32, header[25]) << 24;

    const h_raw = @as(i32, @bitCast(h_u32));
    const h = if (h_raw < 0) @as(u32, @intCast(-h_raw)) else h_u32;

    return .{ .width = w, .height = h };
}

fn parseJpegFile(file: anytype, io: anytype) !struct { width: u16, height: u16 } {
    const size = try std.Io.File.length(file, io);
    var offset: u64 = 2; // skip SOI

    while (offset + 4 <= size) {
        var b: [1]u8 = undefined;
        _ = try std.Io.File.readPositionalAll(file, io, &b, offset);
        if (b[0] != 0xff) {
            offset += 1;
            continue;
        }

        _ = try std.Io.File.readPositionalAll(file, io, &b, offset + 1);
        if (b[0] == 0xff) {
            // padding byte
            offset += 1;
            continue;
        }

        const marker = b[0];
        if (marker == 0xd8) {
            offset += 2;
            continue;
        }
        if (marker == 0xd9 or marker == 0xda) {
            return error.JpegNoDimensions;
        }

        // Read segment length
        var len_buf: [2]u8 = undefined;
        _ = try std.Io.File.readPositionalAll(file, io, &len_buf, offset + 2);
        const segment_len = @as(u16, len_buf[0]) << 8 | len_buf[1];

        // SOF markers: 0xc0 - 0xc3 (and other SOFs)
        const is_sof = (marker >= 0xc0 and marker <= 0xc3) or
            (marker >= 0xc5 and marker <= 0xc7) or
            (marker >= 0xc9 and marker <= 0xcb) or
            (marker >= 0xcd and marker <= 0xcf);

        if (is_sof) {
            if (offset + 9 > size) return error.JpegTooShort;
            var sof_buf: [5]u8 = undefined;
            _ = try std.Io.File.readPositionalAll(file, io, &sof_buf, offset + 4);
            const h = @as(u16, sof_buf[1]) << 8 | sof_buf[2];
            const w = @as(u16, sof_buf[3]) << 8 | sof_buf[4];
            return .{ .width = w, .height = h };
        }

        offset += 2 + segment_len;
    }

    return error.JpegNoDimensions;
}

/// Try parsing a file as an image. Returns dimensions and format on success.
pub fn parseFile(path: []const u8, io: anytype) !struct { format: []const u8, width: u32, height: u32 } {
    const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer std.Io.File.close(file, io);

    var header: [64]u8 = undefined;
    const count = try std.Io.File.readPositionalAll(file, io, &header, 0);
    const data = header[0..count];

    // Try each format.
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
    const header = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0dIHDR\x00\x00\x02\x80\x00\x00\x01\xe0";
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
