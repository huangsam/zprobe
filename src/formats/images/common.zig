const std = @import("std");
const Dir = std.Io.Dir;
const test_utils = @import("../../core/test_utils.zig");

const jpeg = @import("jpeg.zig");
const png = @import("png.zig");
const gif = @import("gif.zig");
const bmp = @import("bmp.zig");
const webp = @import("webp.zig");
const tiff = @import("tiff.zig");
const ico = @import("ico.zig");
const avif = @import("avif.zig");
const jxl = @import("jxl.zig");

/// Extracted metadata from an image file.
pub const ImageMetadata = struct {
    /// The image format (e.g. "jpeg", "png", "gif", "bmp", "webp", "tiff").
    format: []const u8,
    /// Image width in pixels.
    width: u32,
    /// Image height in pixels.
    height: u32,
    /// EXIF orientation value (1-8), if present.
    orientation: ?u16 = null,
    /// EXIF date/time string when the image was captured, if present.
    create_time: ?[]const u8 = null,
    /// EXIF camera manufacturer string, if present.
    camera_make: ?[]const u8 = null,
    /// EXIF camera model string, if present.
    camera_model: ?[]const u8 = null,
    /// GPS latitude coordinate, if present.
    gps_latitude: ?f64 = null,
    /// GPS longitude coordinate, if present.
    gps_longitude: ?f64 = null,

    /// Free heap-allocated strings stored within ImageMetadata.
    pub fn deinit(self: *ImageMetadata, allocator: std.mem.Allocator) void {
        if (self.create_time) |s| allocator.free(s);
        if (self.camera_make) |s| allocator.free(s);
        if (self.camera_model) |s| allocator.free(s);
    }
};

/// Open an image file at the specified absolute path, identify its format,
/// and parse its header to extract layout and metadata details.
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
    errdefer meta.deinit(allocator);

    // Try parsing based on identified magic bytes.
    if (data.len >= 2 and data[0] == jpeg.jpegMagic[0] and data[1] == jpeg.jpegMagic[1]) {
        meta.format = "jpeg";
        var read_buf: [1024]u8 = undefined;
        var f_reader = std.Io.File.reader(file, io, &read_buf);
        const reader = &f_reader.interface;
        const dims = try jpeg.parseJpegFile(allocator, reader, &meta);
        meta.width = dims.width;
        meta.height = dims.height;
        return meta;
    } else if (data.len >= 8 and std.mem.eql(u8, data[0..8], &png.pngMagic)) {
        meta.format = "png";
        try png.parsePngFile(allocator, file, io, &meta);
        return meta;
    } else if (data.len >= 6 and std.mem.eql(u8, data[0..4], &gif.gifMagic)) {
        meta.format = "gif";
        const dims = try gif.parseGif(data);
        meta.width = dims.width;
        meta.height = dims.height;
        return meta;
    } else if (data.len >= 26 and data[0] == bmp.bmpMagic[0] and data[1] == bmp.bmpMagic[1]) {
        meta.format = "bmp";
        const dims = try bmp.parseBmp(data);
        meta.width = dims.width;
        meta.height = dims.height;
        return meta;
    } else if (data.len >= 12 and std.mem.eql(u8, data[0..4], &webp.webpRiffMagic) and std.mem.eql(u8, data[8..12], &webp.webpWebpMagic)) {
        meta.format = "webp";
        try webp.parseWebpFile(allocator, file, io, &meta);
        return meta;
    } else if (data.len >= 4 and std.mem.eql(u8, data[0..4], &ico.icoMagic)) {
        meta.format = "ico";
        const dims = try ico.parseIco(data);
        meta.width = dims.width;
        meta.height = dims.height;
        return meta;
    } else if (data.len >= 12 and std.mem.eql(u8, data[4..8], &avif.avifMagic) and (std.mem.eql(u8, data[8..12], "avif") or std.mem.eql(u8, data[8..12], "avis"))) {
        meta.format = "avif";
        const size = try std.Io.File.length(file, io);
        const dims = try avif.parseAvif(allocator, file, io, size);
        meta.width = dims.width;
        meta.height = dims.height;
        return meta;
    } else if (data.len >= 2 and (std.mem.eql(u8, data[0..2], &jxl.jxlBareMagic) or (data.len >= 12 and std.mem.eql(u8, data[0..12], &jxl.jxlBoxMagic)))) {
        meta.format = "jxl";
        const size = try std.Io.File.length(file, io);
        const dims = try jxl.parseJxl(allocator, file, io, data, size);
        meta.width = dims.width;
        meta.height = dims.height;
        return meta;
    } else if (data.len >= 4 and ((std.mem.eql(u8, data[0..2], "II") and data[2] == 42 and data[3] == 0) or
        (std.mem.eql(u8, data[0..2], "MM") and data[2] == 0 and data[3] == 42)))
    {
        meta.format = "tiff";
        const size = try std.Io.File.length(file, io);
        const tiff_buf = try allocator.alloc(u8, size);
        defer allocator.free(tiff_buf);
        const read = try std.Io.File.readPositionalAll(file, io, tiff_buf, 0);
        if (read < size) return error.TiffTooShort;
        try tiff.parseTiff(allocator, tiff_buf, &meta);
        return meta;
    }

    return error.NotImage;
}

test "parse gif header" {
    const header = "\x47\x49\x46\x38\x39\x61\x40\x01\xf0\x00";
    const dims = try gif.parseGif(header);
    try std.testing.expectEqual(@as(u16, 320), dims.width);
    try std.testing.expectEqual(@as(u16, 240), dims.height);
}

test "parse png header" {
    const header = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0dIHDR\x00\x00\x02\x80\x00\x00\x01\xe0\x08\x02\x00\x00\x00";
    const dims = try png.parsePng(header);
    try std.testing.expectEqual(@as(u32, 640), dims.width);
    try std.testing.expectEqual(@as(u32, 480), dims.height);
}

test "parse jpeg header" {
    const header = "\xff\xd8\xff\xc0\x00\x0b\x08\x00\xf0\x01\x40\x03";
    const dims = try jpeg.parseJpeg(header);
    try std.testing.expectEqual(@as(u16, 320), dims.width);
    try std.testing.expectEqual(@as(u16, 240), dims.height);
}

test "parse bmp header" {
    const header = "BM\x36\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x28\x00\x00\x00\x40\x01\x00\x00\xf0\x00\x00\x00";
    const dims = try bmp.parseBmp(header);
    try std.testing.expectEqual(@as(u32, 320), dims.width);
    try std.testing.expectEqual(@as(u32, 240), dims.height);
}

test "parse png header: too short returns error" {
    const header = "\x89\x50\x4e\x47";
    const result = png.parsePng(header);
    try std.testing.expectEqual(error.NotPng, result);
}

test "parse png header: wrong IHDR type" {
    const header = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0dXXXX\x00\x00\x02\x80\x00\x00\x01\xe0\x08\x02\x00\x00\x00";
    const result = png.parsePng(header);
    try std.testing.expectEqual(error.PngNoIhdr, result);
}

test "parse png header: truncated IHDR chunk" {
    const header = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0a";
    const result = png.parsePng(header);
    try std.testing.expectError(error.PngTooShort, result);
}

test "parse gif header: too short returns error" {
    const header = "\x47\x49\x46\x38";
    const result = gif.parseGif(header);
    try std.testing.expectEqual(error.NotGif, result);
}

test "parse gif header: truncated dimensions" {
    const header = "\x47\x49\x46\x38\x39\x61\x40";
    const result = gif.parseGif(header);
    try std.testing.expectError(error.NotGif, result);
}

test "parse bmp header: too short returns error" {
    const header = "BM\x00";
    const result = bmp.parseBmp(header);
    try std.testing.expectEqual(error.NotBmp, result);
}

test "parse bmp header: wrong magic bytes" {
    const header = "XX\x36\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x28\x00\x00\x00\x40\x01\x00\x00\xf0\x00\x00\x00";
    const result = bmp.parseBmp(header);
    try std.testing.expectEqual(error.NotBmp, result);
}

test "parse jpeg header: no SOF marker returns error" {
    const header = "\xff\xd8\xff\xdb\xff\xd9";
    const result = jpeg.parseJpeg(header);
    try std.testing.expectError(error.JpegNoDimensions, result);
}

test "parse jpeg header: too short for JPEG detection" {
    const header = "\xff\xd8";
    const result = jpeg.parseJpeg(header);
    try std.testing.expectError(error.JpegNoDimensions, result);
}

test "parse jpeg header: single byte returns error" {
    const header = "\xff";
    const result = jpeg.parseJpeg(header);
    try std.testing.expectEqual(error.NotJpeg, result);
}

test "parse jpeg header: SOI only returns error" {
    const header = "\xff\xd8\xff\x00\xff\xd9";
    const result = jpeg.parseJpeg(header);
    try std.testing.expectError(error.JpegNoDimensions, result);
}

test "parse jpeg header: marker 0x00 skipped correctly" {
    const header = "\xff\xd8\xff\x00\xff\xc0\x00\x0b\x08\x00\xf0\x01\x40\x03";
    const dims = try jpeg.parseJpeg(header);
    try std.testing.expectEqual(@as(u16, 320), dims.width);
    try std.testing.expectEqual(@as(u16, 240), dims.height);
}

test "parse jpeg header: consecutive 0xff padding bytes" {
    const header = "\xff\xd8\xff\xff\xff\xff\xff\xc0\x00\x0b\x08\x00\xf0\x01\x40\x03";
    const dims = try jpeg.parseJpeg(header);
    try std.testing.expectEqual(@as(u16, 320), dims.width);
    try std.testing.expectEqual(@as(u16, 240), dims.height);
}

test "parse jpeg header: SOS marker without SOF returns error" {
    const header = "\xff\xd8\xff\xda\xff\x00\x00\x00\xff\xd9";
    const result = jpeg.parseJpeg(header);
    try std.testing.expectError(error.JpegNoDimensions, result);
}

test "parse jpeg header: EOI marker without SOF returns error" {
    const header = "\xff\xd8\xff\xe0\x00\x10\x4a\x46\x49\x46\x00\x01\xff\xd9";
    const result = jpeg.parseJpeg(header);
    try std.testing.expectError(error.JpegNoDimensions, result);
}

test "parse jpeg header: SOF1 (0xc1) also works" {
    const header = "\xff\xd8\xff\xc1\x00\x0c\x08\x04\x38\x07\x80\x03";
    const dims = try jpeg.parseJpeg(header);
    try std.testing.expectEqual(@as(u16, 1920), dims.width);
    try std.testing.expectEqual(@as(u16, 1080), dims.height);
}

test "parse jpeg header: SOF3 (0xc3) also works" {
    const header = "\xff\xd8\xff\xc3\x00\x0b\x08\x02\x58\x03\x20\x03";
    const dims = try jpeg.parseJpeg(header);
    try std.testing.expectEqual(@as(u16, 800), dims.width);
    try std.testing.expectEqual(@as(u16, 600), dims.height);
}

test "parse jpeg header: segment length zero" {
    const header = "\xff\xd8\xff\x00\xff\xc0\x00\x0b\x08\x00\xf0\x01\x40\x03";
    const dims = try jpeg.parseJpeg(header);
    try std.testing.expectEqual(@as(u16, 320), dims.width);
    try std.testing.expectEqual(@as(u16, 240), dims.height);
}

test "parse jpeg header: truncated segment returns error" {
    const header = "\xff\xd8\xff\xc0\x00\x05\x08";
    const result = jpeg.parseJpeg(header);
    try std.testing.expectError(error.JpegTooShort, result);
}

test "parse jpeg header: no SOF in multiple segments" {
    const header = "\xff\xd8\xff\xe0\x00\x10\x4a\x46\x49\x46\x00\x01\x00\x00\x01\x00\x00\xff\xd8\xff\xd9";
    const result = jpeg.parseJpeg(header);
    try std.testing.expectError(error.JpegNoDimensions, result);
}

test "parse WebP: VP8X extended header" {
    const header = "RIFF\x00\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x00\x00\x00\x00\xe7\x03\x00\x1f\x03\x00";
    const dims = try webp.parseWebp(header);
    try std.testing.expectEqual(@as(u32, 1000), dims.width);
    try std.testing.expectEqual(@as(u32, 800), dims.height);
}

test "parse WebP: VP8L lossless header" {
    const header = "RIFF\x00\x00\x00\x00WEBPVP8L\x00\x00\x00\x00\x2f\xe7\xc3\xc7\x00";
    const dims = try webp.parseWebp(header);
    try std.testing.expectEqual(@as(u32, 1000), dims.width);
    try std.testing.expectEqual(@as(u32, 800), dims.height);
}

test "parse WebP: VP8 lossy header" {
    const header = "RIFF\x00\x00\x00\x00WEBPVP8 \x00\x00\x00\x00\x00\x00\x00\x9d\x01\x2a\xe8\x03\x20\x03";
    const dims = try webp.parseWebp(header);
    try std.testing.expectEqual(@as(u32, 1000), dims.width);
    try std.testing.expectEqual(@as(u32, 800), dims.height);
}

test "parse WebP: invalid signature returns error" {
    const header = "RIFF\x00\x00\x00\x00XXXXVP8X\x0a\x00\x00\x00\x00\x00\x00\x00\xe7\x03\x00\x1f\x03\x00";
    const result = webp.parseWebp(header);
    try std.testing.expectError(error.NotWebp, result);
}

test "parse WebP: too short returns error" {
    const header = "RIFF\x00\x00\x00\x00WEBP";
    const result = webp.parseWebp(header);
    try std.testing.expectError(error.WebpTooShort, result);
}

test "parse WebP: VP8L invalid signature byte" {
    const header = "RIFF\x00\x00\x00\x00WEBPVP8L\x00\x00\x00\x00\xff\xe7\xc3\xc7\x00";
    const result = webp.parseWebp(header);
    try std.testing.expectError(error.InvalidWebpVP8L, result);
}

test "parse WebP: VP8 wrong sync code" {
    const header = "RIFF\x00\x00\x00\x00WEBPVP8 \x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xe8\x03\x20\x03";
    const result = webp.parseWebp(header);
    try std.testing.expectError(error.InvalidWebpVP8Sync, result);
}

test "parse WebP: VP8 not keyframe" {
    const header = "RIFF\x00\x00\x00\x00WEBPVP8 \x00\x00\x00\x00\x01\x00\x00\x9d\x01\x2a\xe8\x03\x20\x03";
    const result = webp.parseWebp(header);
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
    buf[0] = 'I';
    buf[1] = 'I';
    buf[2] = 42;
    buf[3] = 0;
    buf[4] = 8;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 0;

    buf[8] = 4;
    buf[9] = 0;

    buf[10] = 0x12;
    buf[11] = 0x01;
    buf[12] = 3;
    buf[13] = 0;
    buf[14] = 1;
    buf[15] = 0;
    buf[16] = 0;
    buf[17] = 0;
    buf[18] = 6;
    buf[19] = 0;
    buf[20] = 0;
    buf[21] = 0;

    buf[22] = 0x0f;
    buf[23] = 0x01;
    buf[24] = 2;
    buf[25] = 0;
    buf[26] = 5;
    buf[27] = 0;
    buf[28] = 0;
    buf[29] = 0;
    buf[30] = 62;
    buf[31] = 0;
    buf[32] = 0;
    buf[33] = 0;

    buf[34] = 0x10;
    buf[35] = 0x01;
    buf[36] = 2;
    buf[37] = 0;
    buf[38] = 4;
    buf[39] = 0;
    buf[40] = 0;
    buf[41] = 0;
    buf[42] = 'A';
    buf[43] = '7';
    buf[44] = 'C';
    buf[45] = 0;

    buf[46] = 0x25;
    buf[47] = 0x88;
    buf[48] = 4;
    buf[49] = 0;
    buf[50] = 1;
    buf[51] = 0;
    buf[52] = 0;
    buf[53] = 0;
    buf[54] = 72;
    buf[55] = 0;
    buf[56] = 0;
    buf[57] = 0;

    @memcpy(buf[62..67], "Sony\x00");

    buf[72] = 4;
    buf[73] = 0;

    buf[74] = 1;
    buf[75] = 0;
    buf[76] = 2;
    buf[77] = 0;
    buf[78] = 2;
    buf[79] = 0;
    buf[80] = 0;
    buf[81] = 0;
    buf[82] = 'N';
    buf[83] = 0;
    buf[84] = 0;
    buf[85] = 0;

    buf[86] = 2;
    buf[87] = 0;
    buf[88] = 5;
    buf[89] = 0;
    buf[90] = 3;
    buf[91] = 0;
    buf[92] = 0;
    buf[93] = 0;
    buf[94] = 124;
    buf[95] = 0;
    buf[96] = 0;
    buf[97] = 0;

    buf[98] = 3;
    buf[99] = 0;
    buf[100] = 2;
    buf[101] = 0;
    buf[102] = 2;
    buf[103] = 0;
    buf[104] = 0;
    buf[105] = 0;
    buf[106] = 'W';
    buf[107] = 0;
    buf[108] = 0;
    buf[109] = 0;

    buf[110] = 4;
    buf[111] = 0;
    buf[112] = 5;
    buf[113] = 0;
    buf[114] = 3;
    buf[115] = 0;
    buf[116] = 0;
    buf[117] = 0;
    buf[118] = 148;
    buf[119] = 0;
    buf[120] = 0;
    buf[121] = 0;

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

    try tiff.parseTiff(allocator, &buf, &meta);

    try std.testing.expectEqual(@as(u16, 6), meta.orientation.?);
    try std.testing.expectEqualStrings("Sony", meta.camera_make.?);
    try std.testing.expectEqualStrings("A7C", meta.camera_model.?);
    try std.testing.expect(meta.gps_latitude.? > 37.7583 and meta.gps_latitude.? < 37.7584);
    try std.testing.expectEqual(@as(f64, -122.0), meta.gps_longitude.?);
}

test "parseTiff width and height tags" {
    const allocator = std.testing.allocator;
    var meta = ImageMetadata{
        .format = "tiff",
        .width = 0,
        .height = 0,
    };
    defer meta.deinit(allocator);

    var buf = [_]u8{0} ** 100;
    buf[0] = 'I';
    buf[1] = 'I';
    buf[2] = 42;
    buf[3] = 0;
    buf[4] = 8;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 0;

    buf[8] = 2;
    buf[9] = 0;

    buf[10] = 0x00;
    buf[11] = 0x01;
    buf[12] = 4;
    buf[13] = 0;
    buf[14] = 1;
    buf[15] = 0;
    buf[16] = 0;
    buf[17] = 0;
    buf[18] = 0x80;
    buf[19] = 0x07;
    buf[20] = 0x00;
    buf[21] = 0x00;

    buf[22] = 0x01;
    buf[23] = 0x01;
    buf[24] = 3;
    buf[25] = 0;
    buf[26] = 1;
    buf[27] = 0;
    buf[28] = 0;
    buf[29] = 0;
    buf[30] = 0x38;
    buf[31] = 0x04;
    buf[32] = 0x00;
    buf[33] = 0x00;

    try tiff.parseTiff(allocator, &buf, &meta);
    try std.testing.expectEqual(@as(u32, 1920), meta.width);
    try std.testing.expectEqual(@as(u32, 1080), meta.height);
}

test "parse PNG file with oversized unrecognized chunk" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;

    var buf = [_]u8{0} ** 40;
    // PNG magic
    @memcpy(buf[0..8], &png.pngMagic);
    // Unrecognized chunk: size = 0xFFFFFFFF, tag = "test"
    buf[8] = 0xFF;
    buf[9] = 0xFF;
    buf[10] = 0xFF;
    buf[11] = 0xFF;
    buf[12] = 't';
    buf[13] = 'e';
    buf[14] = 's';
    buf[15] = 't';

    const temp_filename = "temp_test_png_overflow.png";
    const file = try std.Io.Dir.createFile(temp_dir, io, temp_filename, .{});
    try std.Io.File.writePositionalAll(file, io, &buf, 0);
    std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(temp_dir, io, temp_filename) catch {};

    var meta = ImageMetadata{
        .format = "png",
        .width = 0,
        .height = 0,
    };
    defer meta.deinit(allocator);

    const check_file = try std.Io.Dir.openFile(temp_dir, io, temp_filename, .{ .mode = .read_only });
    defer std.Io.File.close(check_file, io);

    try std.testing.expectError(error.PngTooShort, png.parsePngFile(allocator, check_file, io, &meta));
}

test "parse ICO file with zero images" {
    var header = [_]u8{0} ** 22;
    // Magic: 00 00 01 00
    header[0] = 0x00;
    header[1] = 0x00;
    header[2] = 0x01;
    header[3] = 0x00;
    // Number of images: 00 00 (zero!)
    header[4] = 0x00;
    header[5] = 0x00;

    try std.testing.expectError(error.NotIco, ico.parseIco(&header));
}

test "parseTiff EXIF duplicate tags memory leak" {
    const allocator = std.testing.allocator;
    var meta = ImageMetadata{
        .format = "jpeg",
        .width = 100,
        .height = 100,
    };
    defer meta.deinit(allocator);

    var buf = [_]u8{0} ** 200;
    buf[0] = 'I';
    buf[1] = 'I';
    buf[2] = 42;
    buf[3] = 0;
    buf[4] = 8;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 0;

    // 2 entries, both are Make (0x010f)
    buf[8] = 2;
    buf[9] = 0;

    // Entry 1: Make, type 2, count 5, offset 50
    buf[10] = 0x0f;
    buf[11] = 0x01;
    buf[12] = 2;
    buf[13] = 0;
    buf[14] = 5;
    buf[15] = 0;
    buf[16] = 0;
    buf[17] = 0;
    buf[18] = 50;
    buf[19] = 0;
    buf[20] = 0;
    buf[21] = 0;

    // Entry 2: Make, type 2, count 6, offset 60
    buf[22] = 0x0f;
    buf[23] = 0x01;
    buf[24] = 2;
    buf[25] = 0;
    buf[26] = 6;
    buf[27] = 0;
    buf[28] = 0;
    buf[29] = 0;
    buf[30] = 60;
    buf[31] = 0;
    buf[32] = 0;
    buf[33] = 0;

    @memcpy(buf[50..55], "Sony\x00");
    @memcpy(buf[60..66], "Nikon\x00");

    try tiff.parseTiff(allocator, &buf, &meta);
    try std.testing.expectEqualStrings("Nikon", meta.camera_make.?);
}

test "parse WebP: truncated chunk size" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;
    const temp_filename = "temp_test_webp_trunc.webp";

    const file = try std.Io.Dir.createFile(temp_dir, io, temp_filename, .{});
    defer std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(temp_dir, io, temp_filename) catch {};

    // WEBP header: RIFF + size + WEBP
    var buf = [_]u8{0} ** 30;
    @memcpy(buf[0..4], &webp.webpRiffMagic);
    // Size field (4 bytes): dummy
    @memcpy(buf[8..12], &webp.webpWebpMagic);

    // Chunk header VP8X: size is 2 (less than 10)
    @memcpy(buf[12..16], "VP8X");
    buf[16] = 2;
    buf[17] = 0;
    buf[18] = 0;
    buf[19] = 0;

    try std.Io.File.writePositionalAll(file, io, buf[0..22], 0);

    var meta = ImageMetadata{
        .format = "webp",
        .width = 0,
        .height = 0,
    };
    defer meta.deinit(allocator);

    const check_file = try std.Io.Dir.openFile(temp_dir, io, temp_filename, .{ .mode = .read_only });
    defer std.Io.File.close(check_file, io);

    try std.testing.expectError(error.WebpTooShort, webp.parseWebpFile(allocator, check_file, io, &meta));
}

test "parse bmp header: height i32.min" {
    var header = [_]u8{0} ** 26;
    header[0] = 'B';
    header[1] = 'M';
    header[18] = 100;
    header[22] = 0x00;
    header[23] = 0x00;
    header[24] = 0x00;
    header[25] = 0x80;

    const dims = try bmp.parseBmp(&header);
    try std.testing.expectEqual(@as(u32, 100), dims.width);
    try std.testing.expectEqual(@as(u32, 2147483648), dims.height);
}
