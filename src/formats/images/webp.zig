const std = @import("std");
const tiff = @import("tiff.zig");
const common = @import("common.zig");
const ImageMetadata = common.ImageMetadata;

/// Magic bytes signature identifying a RIFF container header ("RIFF").
pub const webpRiffMagic: [4]u8 = .{ 'R', 'I', 'F', 'F' };

/// Magic bytes signature identifying WebP format payload ("WEBP").
pub const webpWebpMagic: [4]u8 = .{ 'W', 'E', 'B', 'P' };

/// Parse WebP image dimensions from an in-memory header. Handles VP8 (lossy),
/// VP8L (lossless), and VP8X (extended) format chunks.
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
        if ((header[20] & 0x01) != 0) return error.InvalidWebpVP8Keyframe;
        if (header[23] != 0x9d or header[24] != 0x01 or header[25] != 0x2a) {
            return error.InvalidWebpVP8Sync;
        }
        const w = (@as(u16, header[26]) | (@as(u16, header[27]) << 8)) & 0x3fff;
        const h = (@as(u16, header[28]) | (@as(u16, header[29]) << 8)) & 0x3fff;
        return .{ .width = w, .height = h };
    }

    return error.UnsupportedWebpChunk;
}

/// Scan WebP chunks from a file to retrieve width and height, and extract/parse
/// any EXIF metadata chunks if present.
pub fn parseWebpFile(allocator: std.mem.Allocator, file: anytype, io: anytype, meta: *ImageMetadata) !void {
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

        // Use subtraction to avoid integer overflow in bounds check
        // Check: offset + 8 + real_size > size  =>  real_size > size - offset - 8
        if (real_size > size - offset - 8) return error.WebpTooShort;

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
            tiff.parseTiff(allocator, exif_buf, meta) catch {};
        }

        offset += 8 + real_size;
    }

    if (!dims_found) return error.WebpNoDimensions;
}
