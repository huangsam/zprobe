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
            var ext_lower: [16]u8 = undefined;
            const slice = std.ascii.lowerString(&ext_lower, ext);
            if (std.mem.eql(u8, slice, ".webm")) {
                info.format = "webm";
            } else {
                info.format = "mkv";
            }
            return info;
        }
        return error.NoVideoTrack;
    }

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

        if (std.mem.eql(u8, box_type, "moov")) {
            try mp4.findTkhdAndMvhdInFile(allocator, file, io, offset + header_len, offset + real_size, &info);
            if (info.width > 0 and info.height > 0) {
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
