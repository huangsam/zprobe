const std = @import("std");
const tiff = @import("tiff.zig");
const common = @import("common.zig");
const ImageMetadata = common.ImageMetadata;

/// Magic bytes signature identifying a PNG file header.
pub const pngMagic: [8]u8 = .{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };

/// Parse a PNG header from a byte slice to locate the IHDR chunk and extract
/// image width and height. Returns error.NotPng if the signature doesn't match.
pub fn parsePng(header: []const u8) !struct { width: u32, height: u32 } {
    if (header.len < 8 or !std.mem.eql(u8, header[0..8], &pngMagic))
        return error.NotPng;

    if (header.len < 8 + 4 + 4 + 13) return error.PngTooShort;

    const ihdr_len = @as(u32, header[8]) << 24 | @as(u32, header[9]) << 16 |
        @as(u32, header[10]) << 8 | @as(u32, header[11]);
    if (ihdr_len < 13) return error.PngTooShort;

    const type_bytes = header[12..16];
    if (!std.mem.eql(u8, type_bytes, "IHDR")) return error.PngNoIhdr;

    const w = @as(u32, header[16]) << 24 | @as(u32, header[17]) << 16 |
        @as(u32, header[18]) << 8 | @as(u32, header[19]);
    const h = @as(u32, header[20]) << 24 | @as(u32, header[21]) << 16 |
        @as(u32, header[22]) << 8 | @as(u32, header[23]);

    return .{ .width = w, .height = h };
}

/// Scan PNG chunks from a file, extracting dimensions from the IHDR chunk
/// and parsing any eXIf metadata chunks if encountered.
pub fn parsePngFile(allocator: std.mem.Allocator, file: anytype, io: anytype, meta: *ImageMetadata) !void {
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
            tiff.parseTiff(allocator, exif_buf, meta) catch {};
        }

        offset += 12 + chunk_len;
    }

    if (!dims_found) return error.PngNoIhdr;
}
