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

        // 0xff 0xff is a stuffed byte in JPEG streams—skip and continue scanning.
        if (marker == 0xff) {
            off += 1;
            continue;
        }

        // SOF (Start of Frame) markers 0xc0–0xc3 contain image dimensions.
        // Dimensions are at offsets +5, +6 (height) and +7, +8 (width) from the marker.
        if (marker >= 0xc0 and marker <= 0xc3) {
            if (off + 9 > header.len) return error.JpegTooShort;
            const h = @as(u16, header[off + 5]) << 8 | @as(u16, header[off + 6]);
            const w = @as(u16, header[off + 7]) << 8 | @as(u16, header[off + 8]);
            return .{ .width = w, .height = h };
        }

        // Handle markers that don't include a length field (no segment to skip).
        if (marker == 0x00 or marker == 0x01) {
            // Null/padding byte: skip the marker pair only
            off += 2;
        } else if (marker >= 0xd0 and marker <= 0xd7) {
            // RSTn (Restart) markers: no data segment
            off += 2;
        } else if (marker == 0xd8) {
            // SOI (Start of Image): no data segment
            off += 2;
        } else {
            // Other markers (e.g., APP0, APP1, DQT, DHT): have a 2-byte length field.
            // Length includes the 2 bytes for the length itself.
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

test "parseJpegFile: streaming metadata extraction" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_utils = @import("../../core/test_utils.zig");

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;

    const filename = "test_valid.jpg";
    const file = try std.Io.Dir.createFile(temp_dir, io, filename, .{});
    defer std.Io.Dir.deleteFile(temp_dir, io, filename) catch {};

    var buf = [_]u8{0} ** 200;
    // 1. SOI
    @memcpy(buf[0..2], &jpegMagic);

    // 2. APP1 Exif Segment (Marker = FF E1, Size = 100, Payload header = "Exif\0\0")
    buf[2] = 0xff;
    buf[3] = 0xe1;
    buf[4] = 0x00;
    buf[5] = 100; // segment_len
    @memcpy(buf[6..12], "Exif\x00\x00");

    // TIFF Payload inside APP1 chunk starting at absolute offset 12
    const tiff_start = 12;
    buf[tiff_start + 0] = 'I';
    buf[tiff_start + 1] = 'I';
    buf[tiff_start + 2] = 42;
    buf[tiff_start + 4] = 8; // IFD offset

    // IFD at tiff_start + 8 (absolute 20)
    buf[tiff_start + 8] = 1; // 1 entry
    buf[tiff_start + 10] = 0x0f; // Make
    buf[tiff_start + 11] = 0x01;
    buf[tiff_start + 12] = 2; // type ASCII
    buf[tiff_start + 14] = 9; // count = 9
    buf[tiff_start + 18] = 50; // value offset (50 relative to tiff_start, absolute 62)

    // String "JPEGExif\x00" at absolute 62
    @memcpy(buf[tiff_start + 50 .. tiff_start + 59], "JPEGExif\x00");

    // 3. Skip marker APP12 (Marker = FF EC, Size = 10) at absolute 102
    buf[102] = 0xff;
    buf[103] = 0xec;
    buf[104] = 0x00;
    buf[105] = 10;

    // 4. SOF0 Segment (Marker = FF C0, Size = 11, height = 240, width = 320) at absolute 112
    buf[112] = 0xff;
    buf[113] = 0xc0;
    buf[114] = 0x00;
    buf[115] = 11;
    buf[116] = 8; // Precision
    buf[117] = 0; // height MSB
    buf[118] = 240; // height LSB
    buf[119] = 1; // width MSB
    buf[120] = 64; // width LSB (256 + 64 = 320)

    try std.Io.File.writePositionalAll(file, io, buf[0..125], 0);
    std.Io.File.close(file, io);

    var meta = ImageMetadata{
        .format = "jpeg",
        .width = 0,
        .height = 0,
    };
    defer meta.deinit(allocator);

    const check_file = try std.Io.Dir.openFile(temp_dir, io, filename, .{ .mode = .read_only });
    defer std.Io.File.close(check_file, io);

    var read_buf: [1024]u8 = undefined;
    var f_reader = std.Io.File.reader(check_file, io, &read_buf);
    const reader = &f_reader.interface;

    const dims = try parseJpegFile(allocator, reader, &meta);

    try std.testing.expectEqual(@as(u16, 320), dims.width);
    try std.testing.expectEqual(@as(u16, 240), dims.height);
    try std.testing.expectEqualStrings("JPEGExif", meta.camera_make.?);
}

test "parseJpegFile: error handling on bad segments" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_utils = @import("../../core/test_utils.zig");

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;

    // 1. Invalid segment length (< 2)
    {
        const filename = "test_invalid_len.jpg";
        const file = try std.Io.Dir.createFile(temp_dir, io, filename, .{});
        defer std.Io.Dir.deleteFile(temp_dir, io, filename) catch {};

        var buf = [_]u8{0} ** 8;
        @memcpy(buf[0..2], &jpegMagic);
        buf[2] = 0xff;
        buf[3] = 0xe0; // APP0
        buf[4] = 0x00;
        buf[5] = 0x01; // length = 1 (invalid, must be >= 2)

        try std.Io.File.writePositionalAll(file, io, &buf, 0);
        std.Io.File.close(file, io);

        var meta = ImageMetadata{ .format = "jpeg", .width = 0, .height = 0 };
        defer meta.deinit(allocator);

        const check_file = try std.Io.Dir.openFile(temp_dir, io, filename, .{ .mode = .read_only });
        defer std.Io.File.close(check_file, io);

        var read_buf: [1024]u8 = undefined;
        var f_reader = std.Io.File.reader(check_file, io, &read_buf);
        const reader = &f_reader.interface;

        try std.testing.expectError(error.InvalidJpeg, parseJpegFile(allocator, reader, &meta));
    }

    // 2. Truncated segment (length claims 50, file terminates early)
    {
        const filename = "test_trunc_segment.jpg";
        const file = try std.Io.Dir.createFile(temp_dir, io, filename, .{});
        defer std.Io.Dir.deleteFile(temp_dir, io, filename) catch {};

        var buf = [_]u8{0} ** 10;
        @memcpy(buf[0..2], &jpegMagic);
        buf[2] = 0xff;
        buf[3] = 0xe0; // APP0
        buf[4] = 0x00;
        buf[5] = 50; // length = 50 but file is only 10 bytes

        try std.Io.File.writePositionalAll(file, io, &buf, 0);
        std.Io.File.close(file, io);

        var meta = ImageMetadata{ .format = "jpeg", .width = 0, .height = 0 };
        defer meta.deinit(allocator);

        const check_file = try std.Io.Dir.openFile(temp_dir, io, filename, .{ .mode = .read_only });
        defer std.Io.File.close(check_file, io);

        var read_buf: [1024]u8 = undefined;
        var f_reader = std.Io.File.reader(check_file, io, &read_buf);
        const reader = &f_reader.interface;

        try std.testing.expectError(error.EndOfStream, parseJpegFile(allocator, reader, &meta));
    }
}
