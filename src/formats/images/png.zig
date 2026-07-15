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

        if (chunk_len > size - offset - 8) return error.PngTooShort;

        if (std.mem.eql(u8, chunk_tag, "IHDR")) {
            if (chunk_len < 13 or offset + 8 + 13 > size) return error.PngTooShort;
            var payload: [8]u8 = undefined;
            const read = try std.Io.File.readPositionalAll(file, io, &payload, offset + 8);
            if (read < 8) return error.PngTooShort;
            meta.width = @as(u32, payload[0]) << 24 | @as(u32, payload[1]) << 16 | @as(u32, payload[2]) << 8 | payload[3];
            meta.height = @as(u32, payload[4]) << 24 | @as(u32, payload[5]) << 16 | @as(u32, payload[6]) << 8 | payload[7];
            dims_found = true;
        } else if (std.mem.eql(u8, chunk_tag, "eXIf")) {
            const exif_buf = try allocator.alloc(u8, chunk_len);
            defer allocator.free(exif_buf);
            const read = try std.Io.File.readPositionalAll(file, io, exif_buf, offset + 8);
            if (read == chunk_len) {
                tiff.parseTiff(allocator, exif_buf, meta) catch {};
            }
        }

        offset += 12 + chunk_len;
    }

    if (!dims_found) return error.PngNoIhdr;
}

test "parsePngFile: valid PNG file with IHDR and eXIf chunks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_utils = @import("../../core/test_utils.zig");

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;

    const filename = "test_valid.png";
    const file = try std.Io.Dir.createFile(temp_dir, io, filename, .{});
    defer std.Io.Dir.deleteFile(temp_dir, io, filename) catch {};

    var buf = [_]u8{0} ** 80;
    // 1. Signature
    @memcpy(buf[0..8], &pngMagic);

    // 2. IHDR Chunk (size = 13, tag = "IHDR")
    buf[11] = 13;
    @memcpy(buf[12..16], "IHDR");
    // Width = 512 (0x0200)
    buf[18] = 2;
    // Height = 256 (0x0100)
    buf[22] = 1;

    // 3. eXIf Chunk (size = 33, tag = "eXIf")
    // Offset = 8 + 8 (header) + 13 (payload) + 4 (crc) = 33
    buf[36] = 33;
    @memcpy(buf[37..41], "eXIf");

    // tiff payload inside eXIf chunk at offset 41
    const tiff_offset = 41;
    buf[tiff_offset + 0] = 'I';
    buf[tiff_offset + 1] = 'I';
    buf[tiff_offset + 2] = 42;
    buf[tiff_offset + 4] = 8; // IFD offset

    // IFD at tiff_offset + 8
    buf[tiff_offset + 8] = 1; // 1 entry
    buf[tiff_offset + 10] = 0x0f; // Make
    buf[tiff_offset + 11] = 0x01;
    buf[tiff_offset + 12] = 2; // type ASCII
    buf[tiff_offset + 14] = 9; // count = 9
    buf[tiff_offset + 18] = 24; // value offset (24 relative to tiff_offset)

    // String "PNGMaker\x00" at tiff_offset + 24
    @memcpy(buf[tiff_offset + 24 .. tiff_offset + 33], "PNGMaker\x00");

    try std.Io.File.writePositionalAll(file, io, &buf, 0);
    std.Io.File.close(file, io);

    const full_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, filename });
    defer allocator.free(full_path);

    var meta = ImageMetadata{
        .format = "png",
        .width = 0,
        .height = 0,
    };
    defer meta.deinit(allocator);

    const check_file = try std.Io.Dir.openFile(temp_dir, io, filename, .{ .mode = .read_only });
    defer std.Io.File.close(check_file, io);

    try parsePngFile(allocator, check_file, io, &meta);

    try std.testing.expectEqual(@as(u32, 512), meta.width);
    try std.testing.expectEqual(@as(u32, 256), meta.height);
    try std.testing.expectEqualStrings("PNGMaker", meta.camera_make.?);
}

test "parsePngFile: missing IHDR chunk" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_utils = @import("../../core/test_utils.zig");

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;

    const filename = "test_no_ihdr.png";
    const file = try std.Io.Dir.createFile(temp_dir, io, filename, .{});
    defer std.Io.Dir.deleteFile(temp_dir, io, filename) catch {};

    var buf = [_]u8{0} ** 24;
    @memcpy(buf[0..8], &pngMagic);
    buf[11] = 4;
    @memcpy(buf[12..16], "gAMA"); // Some other chunk instead of IHDR

    try std.Io.File.writePositionalAll(file, io, &buf, 0);
    std.Io.File.close(file, io);

    var meta = ImageMetadata{
        .format = "png",
        .width = 0,
        .height = 0,
    };
    defer meta.deinit(allocator);

    const check_file = try std.Io.Dir.openFile(temp_dir, io, filename, .{ .mode = .read_only });
    defer std.Io.File.close(check_file, io);

    try std.testing.expectError(error.PngNoIhdr, parsePngFile(allocator, check_file, io, &meta));
}

test "parsePngFile: truncated chunk data" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_utils = @import("../../core/test_utils.zig");

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;

    const filename = "test_trunc.png";
    const file = try std.Io.Dir.createFile(temp_dir, io, filename, .{});
    defer std.Io.Dir.deleteFile(temp_dir, io, filename) catch {};

    var buf = [_]u8{0} ** 20;
    @memcpy(buf[0..8], &pngMagic);
    buf[11] = 100; // chunk size says 100
    @memcpy(buf[12..16], "IHDR"); // But file terminates here (only 20 bytes total)

    try std.Io.File.writePositionalAll(file, io, &buf, 0);
    std.Io.File.close(file, io);

    var meta = ImageMetadata{
        .format = "png",
        .width = 0,
        .height = 0,
    };
    defer meta.deinit(allocator);

    const check_file = try std.Io.Dir.openFile(temp_dir, io, filename, .{ .mode = .read_only });
    defer std.Io.File.close(check_file, io);

    try std.testing.expectError(error.PngTooShort, parsePngFile(allocator, check_file, io, &meta));
}
