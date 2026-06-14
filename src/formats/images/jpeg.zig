const std = @import("std");
const tiff = @import("tiff.zig");
const common = @import("common.zig");
const ImageMetadata = common.ImageMetadata;

/// Magic bytes signature identifying the start of a JPEG stream.
pub const jpegMagic: [2]u8 = .{ 0xff, 0xd8 };

/// Parse JPEG headers from an in-memory buffer to locate the Start of Frame (SOF) marker
/// and extract width and height. Returns error.NotJpeg if header doesn't start with SOI.
pub fn parseJpeg(header: []const u8) !struct { width: u16, height: u16 } {
    if (header.len < 2 or header[0] != jpegMagic[0] or header[1] != jpegMagic[1])
        return error.NotJpeg;

    var off: usize = 2;
    while (off + 4 <= header.len) {
        if (header[off] != 0xff) {
            off += 1;
            continue;
        }

        const marker = header[off + 1];

        if (marker == 0xff) {
            off += 1;
            continue;
        }

        if (marker >= 0xc0 and marker <= 0xc3) {
            if (off + 9 > header.len) return error.JpegTooShort;
            const h = @as(u16, header[off + 5]) << 8 | @as(u16, header[off + 6]);
            const w = @as(u16, header[off + 7]) << 8 | @as(u16, header[off + 8]);
            return .{ .width = w, .height = h };
        }

        if (marker == 0x00 or marker == 0x01) {
            off += 2;
        } else if (marker >= 0xd0 and marker <= 0xd7) {
            off += 2;
        } else if (marker == 0xd8) {
            off += 2;
        } else {
            const seg_len = @as(u16, header[off + 2]) << 8 | @as(u16, header[off + 3]);
            off += 2 + seg_len;
        }

        if (off > header.len) break;
    }

    return error.JpegNoDimensions;
}

/// Stream-parse a JPEG file using the provided reader to extract dimensions and
/// parse any EXIF APP1 segments for camera/GPS metadata.
pub fn parseJpegFile(allocator: std.mem.Allocator, reader: *std.Io.Reader, meta: *ImageMetadata) !struct { width: u16, height: u16 } {
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
            reader.toss(1);
            continue;
        }

        const marker = marker_bytes[1];
        reader.toss(2);

        if (marker == 0xd8) {
            continue;
        }
        if (marker == 0xd9 or marker == 0xda) {
            return error.JpegNoDimensions;
        }

        const len_bytes = reader.peek(2) catch |err| {
            if (err == error.EndOfStream) return error.JpegTooShort;
            return err;
        };
        const segment_len = @as(u16, len_bytes[0]) << 8 | len_bytes[1];
        reader.toss(2);

        if (segment_len < 2) return error.InvalidJpeg;

        if (marker == 0xe1) {
            const payload_len = segment_len - 2;
            if (payload_len >= 6) {
                const app1_buf = try allocator.alloc(u8, payload_len);
                defer allocator.free(app1_buf);
                try reader.readSliceAll(app1_buf);

                if (std.mem.startsWith(u8, app1_buf, "Exif\x00\x00")) {
                    tiff.parseTiff(allocator, app1_buf[6..], meta) catch {};
                }
            } else {
                try reader.discardAll(payload_len);
            }
            continue;
        }

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

        try reader.discardAll(segment_len - 2);
    }
}
