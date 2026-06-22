const std = @import("std");
const Dir = std.Io.Dir;
const test_utils = @import("../../core/test_utils.zig");
const mp4 = @import("mp4.zig");
const ebml = @import("ebml.zig");

/// Extracted layout and metadata from a video file.
pub const VideoInfo = struct {
    /// The video container format (e.g. "mp4", "mkv", "webm").
    format: []const u8,
    /// Video track width in pixels.
    width: u32,
    /// Video track height in pixels.
    height: u32,
    /// Rotation/orientation mapping value (1: 0°, 3: 180°, 6: 90° CW, 8: 270° CW), if present.
    orientation: ?u16 = null,
    /// The creation time string formatted as "YYYY-MM-DD HH:MM:SS", if present.
    create_time: ?[]const u8 = null,
    /// The duration of the video in seconds, if present.
    duration_sec: ?f64 = null,

    /// Free heap-allocated strings stored within VideoInfo.
    pub fn deinit(self: *VideoInfo, allocator: std.mem.Allocator) void {
        if (self.create_time) |s| allocator.free(s);
    }
};

/// Open a video file at the specified absolute path, determine if it is MP4, MKV,
/// or WebM, and parse its container hierarchy to extract video layout, duration,
/// and metadata.
pub fn getVideoMetadata(allocator: std.mem.Allocator, path: []const u8, io: anytype) !VideoInfo {
    const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer std.Io.File.close(file, io);

    const size = try std.Io.File.length(file, io);

    var info = VideoInfo{
        .format = "mp4",
        .width = 0,
        .height = 0,
    };

    var first_bytes: [4]u8 = undefined;
    const read_len = try std.Io.File.readPositionalAll(file, io, &first_bytes, 0);
    if (read_len >= 4 and std.mem.eql(u8, &first_bytes, "\x1A\x45\xDF\xA3")) {
        var state = ebml.EbmlState{};
        try ebml.parseEbmlElements(file, io, 0, size, &state, 0);
        if (state.width > 0 and state.height > 0) {
            info.width = state.width;
            info.height = state.height;
            if (state.duration_raw) |raw_dur| {
                info.duration_sec = raw_dur * @as(f64, @floatFromInt(state.timecode_scale)) / 1_000_000_000.0;
            }
            const media_scan = @import("../../crawler/media_scan.zig");
            const ext = media_scan.getExtension(path);
            var is_webm = false;
            if (ext.len > 0 and ext.len <= 16) {
                var ext_lower: [16]u8 = undefined;
                const slice = std.ascii.lowerString(ext_lower[0..ext.len], ext);
                if (std.mem.eql(u8, slice, ".webm")) {
                    is_webm = true;
                }
            }
            if (is_webm) {
                info.format = "webm";
            } else {
                info.format = "mkv";
            }
            return info;
        }
        return error.NoVideoTrack;
    }

    // Track whether we found an ftyp box and whether its brand is QuickTime.
    var found_ftyp = false;
    var is_qt_brand = false;

    var offset: u64 = 0;
    while (offset + 8 <= size) {
        var header_buf: [8]u8 = undefined;
        _ = try std.Io.File.readPositionalAll(file, io, &header_buf, offset);

        const box_size = @as(u64, header_buf[0]) << 24 |
            @as(u64, header_buf[1]) << 16 |
            @as(u64, header_buf[2]) << 8 |
            @as(u64, header_buf[3]);

        const box_type = header_buf[4..8];

        var header_len: u64 = 8;
        var real_size = box_size;

        // Extended 64-bit size box (indicated by size == 1)
        if (box_size == 1) {
            if (offset + 16 > size) return error.InvalidMp4;
            var ext_size_buf: [8]u8 = undefined;
            _ = try std.Io.File.readPositionalAll(file, io, &ext_size_buf, offset + 8);
            real_size = @as(u64, ext_size_buf[0]) << 56 |
                @as(u64, ext_size_buf[1]) << 48 |
                @as(u64, ext_size_buf[2]) << 40 |
                @as(u64, ext_size_buf[3]) << 32 |
                @as(u64, ext_size_buf[4]) << 24 |
                @as(u64, ext_size_buf[5]) << 16 |
                @as(u64, ext_size_buf[6]) << 8 |
                @as(u64, ext_size_buf[7]);
            header_len = 16;
        }

        // If size is 0, it extends to the end of the file
        if (real_size == 0) {
            real_size = size - offset;
        }

        // Use subtraction to avoid integer overflow in bounds check
        if (real_size < header_len or real_size > size - offset) return error.InvalidMp4;

        if (std.mem.eql(u8, box_type, "ftyp")) {
            // The ftyp payload begins with a 4-byte major brand that identifies
            // the container dialect (e.g. "qt  " for QuickTime/MOV, "mp41" for MP4).
            const payload_len = real_size - header_len;
            if (payload_len >= 4) {
                var brand_buf: [4]u8 = undefined;
                _ = try std.Io.File.readPositionalAll(file, io, &brand_buf, offset + header_len);
                found_ftyp = true;
                if (std.mem.eql(u8, &brand_buf, "qt  ")) {
                    is_qt_brand = true;
                }
            }
        } else if (std.mem.eql(u8, box_type, "moov")) {
            try mp4.findTkhdAndMvhdInFile(allocator, file, io, offset + header_len, offset + real_size, &info, 0);
            if (info.width > 0 and info.height > 0) {
                if (is_qt_brand) {
                    info.format = "mov";
                } else if (!found_ftyp) {
                    // Older QuickTime files start directly with moov and have no
                    // ftyp box, so fall back to extension-based detection.
                    const media_scan = @import("../../crawler/media_scan.zig");
                    const ext = media_scan.getExtension(path);
                    if (ext.len > 0 and ext.len <= 16) {
                        var ext_lower: [16]u8 = undefined;
                        const slice = std.ascii.lowerString(ext_lower[0..ext.len], ext);
                        if (std.mem.eql(u8, slice, ".mov")) {
                            info.format = "mov";
                        }
                    }
                }
                return info;
            }
            return error.NoVideoTrack;
        }

        offset += real_size;
    }

    return error.NotVideo;
}

test "getVideoMetadata: parse mock WebM file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;
    const temp_filename = "temp_test_ebml.webm";

    const file = try std.Io.Dir.createFile(temp_dir, io, temp_filename, .{});
    defer std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(temp_dir, io, temp_filename) catch {};

    var buf = [_]u8{0} ** 59;
    buf[0] = 0x1A;
    buf[1] = 0x45;
    buf[2] = 0xDF;
    buf[3] = 0xA3; // EBML Header ID
    buf[4] = 0x8A; // EBML Header Size (10 bytes)

    // Segment ID (0x18538067)
    buf[15] = 0x18;
    buf[16] = 0x53;
    buf[17] = 0x80;
    buf[18] = 0x67;
    // Segment Size (39 -> 0xA7)
    buf[19] = 0xA7;

    // Info ID (0x1549A966)
    buf[20] = 0x15;
    buf[21] = 0x49;
    buf[22] = 0xA9;
    buf[23] = 0x66;
    // Info Size (14 -> 0x8E)
    buf[24] = 0x8E;

    // TimecodeScale ID (0x2AD7B1)
    buf[25] = 0x2A;
    buf[26] = 0xD7;
    buf[27] = 0xB1;
    // TimecodeScale Size (3 -> 0x83)
    buf[28] = 0x83;
    // TimecodeScale Value (1,000,000 -> 0x0F4240)
    buf[29] = 0x0F;
    buf[30] = 0x42;
    buf[31] = 0x40;

    // Duration ID (0x4489)
    buf[32] = 0x44;
    buf[33] = 0x89;
    // Duration Size (4 -> 0x84)
    buf[34] = 0x84;
    // Duration Value (5.5 -> 0x40B00000)
    buf[35] = 0x40;
    buf[36] = 0xB0;
    buf[37] = 0x00;
    buf[38] = 0x00;

    // Tracks ID (0x1654AE6B)
    buf[39] = 0x16;
    buf[40] = 0x54;
    buf[41] = 0xAE;
    buf[42] = 0x6B;
    // Tracks Size (15 -> 0x8F)
    buf[43] = 0x8F;

    // TrackEntry ID (0xAE)
    buf[44] = 0xAE;
    // TrackEntry Size (13 -> 0x8D)
    buf[45] = 0x8D;

    // TrackType ID (0x83)
    buf[46] = 0x83;
    // TrackType Size (1 -> 0x81)
    buf[47] = 0x81;
    // TrackType Value (1 -> 0x01)
    buf[48] = 0x01;

    // Video ID (0xE0)
    buf[49] = 0xE0;
    // Video Size (8 -> 0x88)
    buf[50] = 0x88;

    // PixelWidth ID (0xB0)
    buf[51] = 0xB0;
    // PixelWidth Size (2 -> 0x82)
    buf[52] = 0x82;
    // PixelWidth Value (1920 -> 0x0780)
    buf[53] = 0x07;
    buf[54] = 0x80;

    // PixelHeight ID (0xBA)
    buf[55] = 0xBA;
    // PixelHeight Size (2 -> 0x82)
    buf[56] = 0x82;
    // PixelHeight Value (1080 -> 0x0438)
    buf[57] = 0x04;
    buf[58] = 0x38;

    try std.Io.File.writePositionalAll(file, io, &buf, 0);

    const abs_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, temp_filename });
    defer allocator.free(abs_path);

    var res = try getVideoMetadata(allocator, abs_path, io);
    defer res.deinit(allocator);

    try std.testing.expectEqualStrings("webm", res.format);
    try std.testing.expectEqual(@as(u32, 1920), res.width);
    try std.testing.expectEqual(@as(u32, 1080), res.height);
    try std.testing.expect(res.duration_sec.? > 0.00549 and res.duration_sec.? < 0.00551);
}

test "getVideoMetadata: parse mock EBML file with long extension does not panic" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;
    const temp_filename = "temp_test_ebml.extremelylongextensionnamehere";

    const file = try std.Io.Dir.createFile(temp_dir, io, temp_filename, .{});
    defer std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(temp_dir, io, temp_filename) catch {};

    var buf = [_]u8{0} ** 59;
    buf[0] = 0x1A;
    buf[1] = 0x45;
    buf[2] = 0xDF;
    buf[3] = 0xA3; // EBML Header ID
    buf[4] = 0x8A; // EBML Header Size (10 bytes)

    // Segment ID (0x18538067)
    buf[15] = 0x18;
    buf[16] = 0x53;
    buf[17] = 0x80;
    buf[18] = 0x67;
    // Segment Size (39 -> 0xA7)
    buf[19] = 0xA7;

    // Info ID (0x1549A966)
    buf[20] = 0x15;
    buf[21] = 0x49;
    buf[22] = 0xA9;
    buf[23] = 0x66;
    // Info Size (14 -> 0x8E)
    buf[24] = 0x8E;

    // TimecodeScale ID (0x2AD7B1)
    buf[25] = 0x2A;
    buf[26] = 0xD7;
    buf[27] = 0xB1;
    // TimecodeScale Size (3 -> 0x83)
    buf[28] = 0x83;
    // TimecodeScale Value (1,000,000 -> 0x0F4240)
    buf[29] = 0x0F;
    buf[30] = 0x42;
    buf[31] = 0x40;

    // Duration ID (0x4489)
    buf[32] = 0x44;
    buf[33] = 0x89;
    // Duration Size (4 -> 0x84)
    buf[34] = 0x84;
    // Duration Value (5.5 -> 0x40B00000)
    buf[35] = 0x40;
    buf[36] = 0xB0;
    buf[37] = 0x00;
    buf[38] = 0x00;

    // Tracks ID (0x1654AE6B)
    buf[39] = 0x16;
    buf[40] = 0x54;
    buf[41] = 0xAE;
    buf[42] = 0x6B;
    // Tracks Size (15 -> 0x8F)
    buf[43] = 0x8F;

    // TrackEntry ID (0xAE)
    buf[44] = 0xAE;
    // TrackEntry Size (13 -> 0x8D)
    buf[45] = 0x8D;

    // TrackType ID (0x83)
    buf[46] = 0x83;
    // TrackType Size (1 -> 0x81)
    buf[47] = 0x81;
    // TrackType Value (1 -> 0x01)
    buf[48] = 0x01;

    // Video ID (0xE0)
    buf[49] = 0xE0;
    // Video Size (8 -> 0x88)
    buf[50] = 0x88;

    // PixelWidth ID (0xB0)
    buf[51] = 0xB0;
    // PixelWidth Size (2 -> 0x82)
    buf[52] = 0x82;
    // PixelWidth Value (1920 -> 0x0780)
    buf[53] = 0x07;
    buf[54] = 0x80;

    // PixelHeight ID (0xBA)
    buf[55] = 0xBA;
    // PixelHeight Size (2 -> 0x82)
    buf[56] = 0x82;
    // PixelHeight Value (1080 -> 0x0438)
    buf[57] = 0x04;
    buf[58] = 0x38;

    try std.Io.File.writePositionalAll(file, io, &buf, 0);

    const abs_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, temp_filename });
    defer allocator.free(abs_path);

    var res = try getVideoMetadata(allocator, abs_path, io);
    defer res.deinit(allocator);

    // Format should fallback to "mkv" because extension is not ".webm"
    try std.testing.expectEqualStrings("mkv", res.format);
}

test "getVideoMetadata: modern MOV with ftyp qt   brand" {
    // Constructs a minimal QuickTime/MOV file:
    //   [ftyp box (20 bytes)] [moov box (108 bytes)]
    //     moov -> trak -> tkhd (version 0, 1280×720)
    //
    // ftyp box layout (20 bytes):
    //   0-3:   size = 20
    //   4-7:   "ftyp"
    //   8-11:  major brand = "qt  " (QuickTime)
    //   12-15: minor version = 0
    //   16-19: compatible brand = "qt  "
    //
    // tkhd payload offsets (relative to tkhd box start at file byte 36):
    //   +8:  version (1 byte)
    //   +9:  flags (3 bytes)
    //   +12: creation_time/modification_time/track_id/reserved/duration (20 bytes)
    //   +32: reserved2 (8 bytes)
    //   +40: layer,alt-group,volume,reserved3 (8 bytes)
    //   +48: matrix a,b,u,c,d,v,tx,ty,w (9×4 = 36 bytes)
    //   +84: width_int (2 bytes big-endian)
    //   +86: skip 2
    //   +88: height_int (2 bytes big-endian)
    //   +90: skip 2  →  tkhd payload = 84 bytes, box = 92 bytes
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;
    const temp_filename = "test_qt.mov";

    const file = try std.Io.Dir.createFile(temp_dir, io, temp_filename, .{});
    defer std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(temp_dir, io, temp_filename) catch {};

    var buf = [_]u8{0} ** 128;

    // ftyp box (bytes 0–19)
    buf[0] = 0x00;
    buf[1] = 0x00;
    buf[2] = 0x00;
    buf[3] = 0x14; // size = 20
    buf[4] = 'f';
    buf[5] = 't';
    buf[6] = 'y';
    buf[7] = 'p';
    buf[8] = 'q';
    buf[9] = 't';
    buf[10] = ' ';
    buf[11] = ' '; // major brand: "qt  "
    // minor version = 0 (bytes 12–15)
    buf[16] = 'q';
    buf[17] = 't';
    buf[18] = ' ';
    buf[19] = ' '; // compatible brand

    // moov box (bytes 20–127, size = 108)
    buf[20] = 0x00;
    buf[21] = 0x00;
    buf[22] = 0x00;
    buf[23] = 0x6c;
    buf[24] = 'm';
    buf[25] = 'o';
    buf[26] = 'o';
    buf[27] = 'v';

    // trak box (bytes 28–127, size = 100)
    buf[28] = 0x00;
    buf[29] = 0x00;
    buf[30] = 0x00;
    buf[31] = 0x64;
    buf[32] = 't';
    buf[33] = 'r';
    buf[34] = 'a';
    buf[35] = 'k';

    // tkhd box (bytes 36–127, size = 92)
    buf[36] = 0x00;
    buf[37] = 0x00;
    buf[38] = 0x00;
    buf[39] = 0x5c;
    buf[40] = 't';
    buf[41] = 'k';
    buf[42] = 'h';
    buf[43] = 'd';
    // version = 0 at buf[44], flags zeros at buf[45–47]
    // creation_time/modification_time/track_id/reserved/duration zeros at buf[48–67]
    // reserved2 zeros at buf[68–75]
    // layer/alt-group/volume/reserved3 zeros at buf[76–83]
    // matrix identity: a=1.0 at buf[84–87], d=1.0 at buf[100–103], rest zero
    buf[84] = 0x00;
    buf[85] = 0x01;
    buf[86] = 0x00;
    buf[87] = 0x00; // a = 0x00010000
    buf[100] = 0x00;
    buf[101] = 0x01;
    buf[102] = 0x00;
    buf[103] = 0x00; // d = 0x00010000
    // width = 1280 = 0x0500 at buf[120–121]
    buf[120] = 0x05;
    buf[121] = 0x00;
    // height = 720 = 0x02D0 at buf[124–125]
    buf[124] = 0x02;
    buf[125] = 0xD0;

    try std.Io.File.writePositionalAll(file, io, &buf, 0);

    const abs_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, temp_filename });
    defer allocator.free(abs_path);

    var res = try getVideoMetadata(allocator, abs_path, io);
    defer res.deinit(allocator);

    try std.testing.expectEqualStrings("mov", res.format);
    try std.testing.expectEqual(@as(u32, 1280), res.width);
    try std.testing.expectEqual(@as(u32, 720), res.height);
}

test "getVideoMetadata: legacy MOV without ftyp box falls back to extension" {
    // Older QuickTime files omit the ftyp box and start directly with moov.
    // zprobe should detect the .mov extension and label the format "mov".
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;
    const temp_filename = "test_legacy.mov";

    const file = try std.Io.Dir.createFile(temp_dir, io, temp_filename, .{});
    defer std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(temp_dir, io, temp_filename) catch {};

    // File is just the moov box (no preceding ftyp), 108 bytes.
    var buf = [_]u8{0} ** 108;

    // moov box (bytes 0–107, size = 108)
    buf[0] = 0x00;
    buf[1] = 0x00;
    buf[2] = 0x00;
    buf[3] = 0x6c;
    buf[4] = 'm';
    buf[5] = 'o';
    buf[6] = 'o';
    buf[7] = 'v';

    // trak box (bytes 8–107, size = 100)
    buf[8] = 0x00;
    buf[9] = 0x00;
    buf[10] = 0x00;
    buf[11] = 0x64;
    buf[12] = 't';
    buf[13] = 'r';
    buf[14] = 'a';
    buf[15] = 'k';

    // tkhd box (bytes 16–107, size = 92)
    buf[16] = 0x00;
    buf[17] = 0x00;
    buf[18] = 0x00;
    buf[19] = 0x5c;
    buf[20] = 't';
    buf[21] = 'k';
    buf[22] = 'h';
    buf[23] = 'd';
    // version = 0 at buf[24]; flags/reserved zeros through buf[47]
    // matrix: a=1.0 at buf[64–67], d=1.0 at buf[80–83]
    buf[64] = 0x00;
    buf[65] = 0x01;
    buf[66] = 0x00;
    buf[67] = 0x00; // a
    buf[80] = 0x00;
    buf[81] = 0x01;
    buf[82] = 0x00;
    buf[83] = 0x00; // d
    // width = 1920 = 0x0780 at buf[100–101]
    buf[100] = 0x07;
    buf[101] = 0x80;
    // height = 1080 = 0x0438 at buf[104–105]
    buf[104] = 0x04;
    buf[105] = 0x38;

    try std.Io.File.writePositionalAll(file, io, &buf, 0);

    const abs_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, temp_filename });
    defer allocator.free(abs_path);

    var res = try getVideoMetadata(allocator, abs_path, io);
    defer res.deinit(allocator);

    try std.testing.expectEqualStrings("mov", res.format);
    try std.testing.expectEqual(@as(u32, 1920), res.width);
    try std.testing.expectEqual(@as(u32, 1080), res.height);
}

test "getVideoMetadata: EBML file with invalid ID size does not panic" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;
    const temp_filename = "temp_invalid_ebml.webm";

    const file = try std.Io.Dir.createFile(temp_dir, io, temp_filename, .{});
    defer std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(temp_dir, io, temp_filename) catch {};

    var buf = [_]u8{0} ** 59;
    buf[0] = 0x1A;
    buf[1] = 0x45;
    buf[2] = 0xDF;
    buf[3] = 0xA3; // EBML Header ID
    buf[4] = 0x8A; // EBML Header Size

    // Segment ID starts with 0x08, indicating a 5-byte VINT ID, which is invalid (must be 1-4 bytes)
    buf[15] = 0x08;
    buf[16] = 0x00;
    buf[17] = 0x00;
    buf[18] = 0x00;
    buf[19] = 0x00;

    try std.Io.File.writePositionalAll(file, io, &buf, 0);

    const abs_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, temp_filename });
    defer allocator.free(abs_path);

    try std.testing.expectError(error.InvalidEbmlId, getVideoMetadata(allocator, abs_path, io));
}

test "getVideoMetadata: MP4 with truncated 64-bit size box returns InvalidMp4" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;
    const temp_filename = "temp_truncated_64bit.mp4";

    const file = try std.Io.Dir.createFile(temp_dir, io, temp_filename, .{});
    defer std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(temp_dir, io, temp_filename) catch {};

    // 12 bytes of data (size is 12)
    var buf = [_]u8{0} ** 12;
    buf[0] = 0x00;
    buf[1] = 0x00;
    buf[2] = 0x00;
    buf[3] = 0x01; // box_size = 1 (indicates 64-bit size, which requires 8 more bytes)
    buf[4] = 'f';
    buf[5] = 't';
    buf[6] = 'y';
    buf[7] = 'p';
    // Only 4 more bytes left, so cannot read the 8-byte 64-bit size.

    try std.Io.File.writePositionalAll(file, io, &buf, 0);

    const abs_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, temp_filename });
    defer allocator.free(abs_path);

    try std.testing.expectError(error.InvalidMp4, getVideoMetadata(allocator, abs_path, io));
}
