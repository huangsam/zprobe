//! Educational MP4 Metadata Parser.
//!
//! This module showcases:
//! 1. Recursive parsing of the MP4 (ISOBMFF) container format tree structure.
//! 2. Parsing Big-Endian binary integers.
//! 3. Extracting 16.16 fixed-point numbers.
//! 4. Smart I/O design: reading only metadata box payloads while skipping massive video data.

const std = @import("std");
const Dir = std.Io.Dir;
const utils = @import("utils.zig");

pub const VideoInfo = struct {
    format: []const u8,
    width: u32,
    height: u32,
    orientation: ?u16 = null,
    create_time: ?[]const u8 = null,
    duration_sec: ?f64 = null,

    pub fn deinit(self: *VideoInfo, allocator: std.mem.Allocator) void {
        if (self.create_time) |s| allocator.free(s);
    }
};

const Dims = struct {
    width: u32,
    height: u32,
    orientation: u16 = 1,
};

/// Parse a `tkhd` (Track Header) box payload.
fn parseTkhd(payload: []const u8) ?Dims {
    if (payload.len < 80) return null;

    const version = payload[0];
    var w_off: usize = 0;
    var h_off: usize = 0;
    var m_off: usize = 0;

    if (version == 0) {
        if (payload.len < 84) return null;
        w_off = 76;
        h_off = 80;
        m_off = 40;
    } else if (version == 1) {
        if (payload.len < 96) return null;
        w_off = 88;
        h_off = 92;
        m_off = 52;
    } else {
        return null;
    }

    // Decode Big-Endian 16-bit integer part of the 16.16 fixed point value.
    const w = @as(u32, payload[w_off]) << 8 | @as(u32, payload[w_off + 1]);
    const h = @as(u32, payload[h_off]) << 8 | @as(u32, payload[h_off + 1]);

    // Parse matrix for rotation
    const a = @as(i32, @bitCast(@as(u32, payload[m_off]) << 24 | @as(u32, payload[m_off + 1]) << 16 | @as(u32, payload[m_off + 2]) << 8 | payload[m_off + 3]));
    const b = @as(i32, @bitCast(@as(u32, payload[m_off + 4]) << 24 | @as(u32, payload[m_off + 5]) << 16 | @as(u32, payload[m_off + 6]) << 8 | payload[m_off + 7]));
    const c = @as(i32, @bitCast(@as(u32, payload[m_off + 12]) << 24 | @as(u32, payload[m_off + 13]) << 16 | @as(u32, payload[m_off + 14]) << 8 | payload[m_off + 15]));
    const d = @as(i32, @bitCast(@as(u32, payload[m_off + 16]) << 24 | @as(u32, payload[m_off + 17]) << 16 | @as(u32, payload[m_off + 18]) << 8 | payload[m_off + 19]));

    var orientation: u16 = 1;
    if (b == 0x00010000 and c == -0x00010000) {
        orientation = 6;
    } else if (a == -0x00010000 and d == -0x00010000) {
        orientation = 3;
    } else if (b == -0x00010000 and c == 0x00010000) {
        orientation = 8;
    }

    return .{ .width = w, .height = h, .orientation = orientation };
}

/// Recursively search for the `tkhd` box within nested container boxes.
fn findTkhdInPayload(payload: []const u8) ?Dims {
    var off: usize = 0;
    while (off + 8 <= payload.len) {
        // Read box size (4 bytes, Big-Endian)
        const box_size = @as(u32, payload[off]) << 24 |
            @as(u32, payload[off + 1]) << 16 |
            @as(u32, payload[off + 2]) << 8 |
            @as(u32, payload[off + 3]);
        if (box_size < 8 or off + box_size > payload.len) return null;

        // Read box type (4 bytes ASCII)
        const box_type = payload[off + 4 .. off + 8];
        if (std.mem.eql(u8, box_type, "tkhd")) {
            const tkhd_payload = payload[off + 8 .. off + box_size];
            if (parseTkhd(tkhd_payload)) |dims| {
                if (dims.width > 0 and dims.height > 0) {
                    return dims;
                }
            }
        }

        // If this box is a container type, recurse into its inner payload.
        if (std.mem.eql(u8, box_type, "trak") or
            std.mem.eql(u8, box_type, "mdia") or
            std.mem.eql(u8, box_type, "minf") or
            std.mem.eql(u8, box_type, "stbl"))
        {
            if (findTkhdInPayload(payload[off + 8 .. off + box_size])) |dims| {
                return dims;
            }
        }

        off += box_size;
    }
    return null;
}

fn parseMvhd(allocator: std.mem.Allocator, payload: []const u8, info: *VideoInfo) !void {
    if (payload.len < 20) return;

    const version = payload[0];
    var timescale: u32 = 0;
    var duration: u64 = 0;
    var creation_time: u64 = 0;

    if (version == 0) {
        creation_time = @as(u32, payload[4]) << 24 | @as(u32, payload[5]) << 16 | @as(u32, payload[6]) << 8 | payload[7];
        timescale = @as(u32, payload[12]) << 24 | @as(u32, payload[13]) << 16 | @as(u32, payload[14]) << 8 | payload[15];
        duration = @as(u32, payload[16]) << 24 | @as(u32, payload[17]) << 16 | @as(u32, payload[18]) << 8 | payload[19];
    } else if (version == 1) {
        if (payload.len < 32) return;
        creation_time = @as(u64, payload[4]) << 56 | @as(u64, payload[5]) << 48 | @as(u64, payload[6]) << 40 | @as(u64, payload[7]) << 32 |
            @as(u64, payload[8]) << 24 | @as(u64, payload[9]) << 16 | @as(u64, payload[10]) << 8 | payload[11];
        timescale = @as(u32, payload[20]) << 24 | @as(u32, payload[21]) << 16 | @as(u32, payload[22]) << 8 | payload[23];
        duration = @as(u64, payload[24]) << 56 | @as(u64, payload[25]) << 48 | @as(u64, payload[26]) << 40 | @as(u64, payload[27]) << 32 |
            @as(u64, payload[28]) << 24 | @as(u64, payload[29]) << 16 | @as(u64, payload[30]) << 8 | payload[31];
    } else {
        return;
    }

    if (timescale > 0) {
        info.duration_sec = @as(f64, @floatFromInt(duration)) / @as(f64, @floatFromInt(timescale));
    }

    // Convert creation_time (seconds since Jan 1, 1904) to Unix time
    if (creation_time >= 2082844800) {
        const unix_secs = creation_time - 2082844800;
        info.create_time = utils.formatEpoch(allocator, unix_secs) catch null;
    }
}

fn findTkhdAndMvhdInFile(allocator: std.mem.Allocator, file: anytype, io: anytype, start_offset: u64, end_offset: u64, info: *VideoInfo) !void {
    var offset = start_offset;
    while (offset + 8 <= end_offset) {
        var header_buf: [8]u8 = undefined;
        _ = try std.Io.File.readPositionalAll(file, io, &header_buf, offset);

        const box_size = @as(u64, header_buf[0]) << 24 |
            @as(u64, header_buf[1]) << 16 |
            @as(u64, header_buf[2]) << 8 |
            @as(u64, header_buf[3]);

        const box_type = header_buf[4..8];

        var header_len: u64 = 8;
        var real_size = box_size;

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

        if (real_size == 0) {
            real_size = end_offset - offset;
        }

        if (real_size < header_len or offset + real_size > end_offset) return error.InvalidMp4;

        if (std.mem.eql(u8, box_type, "mvhd")) {
            const payload_len = real_size - header_len;
            var mvhd_buf: [36]u8 = undefined;
            const read_len = @min(payload_len, mvhd_buf.len);
            _ = try std.Io.File.readPositionalAll(file, io, mvhd_buf[0..read_len], offset + header_len);
            try parseMvhd(allocator, mvhd_buf[0..read_len], info);
        } else if (std.mem.eql(u8, box_type, "tkhd")) {
            const payload_len = real_size - header_len;
            var tkhd_buf: [96]u8 = undefined;
            const read_len = @min(payload_len, tkhd_buf.len);
            _ = try std.Io.File.readPositionalAll(file, io, tkhd_buf[0..read_len], offset + header_len);
            if (parseTkhd(tkhd_buf[0..read_len])) |dims| {
                if (dims.width > 0 and dims.height > 0) {
                    info.width = dims.width;
                    info.height = dims.height;
                    info.orientation = dims.orientation;
                }
            }
        } else if (std.mem.eql(u8, box_type, "trak") or
            std.mem.eql(u8, box_type, "mdia") or
            std.mem.eql(u8, box_type, "minf") or
            std.mem.eql(u8, box_type, "stbl"))
        {
            try findTkhdAndMvhdInFile(allocator, file, io, offset + header_len, offset + real_size, info);
        }

        offset += real_size;
    }
}

/// Try parsing a video file. Returns format and dimensions on success.
///
/// ### Memory Allocation & Performance Strategy:
/// - MP4 files can be massive (gigabytes of compressed stream data in `mdat`).
/// - However, the metadata (`moov` box) is typically very small.
/// - This parser scans the file linearly, reading only the 8-byte box headers.
/// - The search for the track header (`tkhd`) and movie header (`mvhd`) is done recursively in-place within the file,
///   completely avoiding loading the `moov` payload into memory.
pub fn getVideoMetadata(allocator: std.mem.Allocator, path: []const u8, io: anytype) !VideoInfo {
    const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer std.Io.File.close(file, io);

    const size = try std.Io.File.length(file, io);

    var info = VideoInfo{
        .format = "mp4",
        .width = 0,
        .height = 0,
    };

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

        if (real_size < header_len or offset + real_size > size) return error.InvalidMp4;

        if (std.mem.eql(u8, box_type, "moov")) {
            try findTkhdAndMvhdInFile(allocator, file, io, offset + header_len, offset + real_size, &info);
            if (info.width > 0 and info.height > 0) {
                return info;
            }
            return error.NoVideoTrack;
        }

        offset += real_size;
    }

    return error.NotVideo;
}

test "parse MP4 moov/trak/tkhd version 0 payload" {
    var buf = [_]u8{0} ** 120;

    // trak box header at offset 0: size 100, type "trak"
    const trak_size: u32 = 100;
    buf[0] = @intCast(trak_size >> 24);
    buf[1] = @intCast((trak_size >> 16) & 0xff);
    buf[2] = @intCast((trak_size >> 8) & 0xff);
    buf[3] = @intCast(trak_size & 0xff);
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    // tkhd box header at offset 8: size 92, type "tkhd"
    const tkhd_size: u32 = 92;
    buf[8] = @intCast(tkhd_size >> 24);
    buf[9] = @intCast((tkhd_size >> 16) & 0xff);
    buf[10] = @intCast((tkhd_size >> 8) & 0xff);
    buf[11] = @intCast(tkhd_size & 0xff);
    buf[12] = 't';
    buf[13] = 'k';
    buf[14] = 'h';
    buf[15] = 'd';

    // version = 0 (offset 16)
    buf[16] = 0;

    // width: 640 (offset 16 + 76 = 92) -> 02 80 00 00
    buf[92] = 0x02;
    buf[93] = 0x80;

    // height: 480 (offset 16 + 80 = 96) -> 01 e0 00 00
    buf[96] = 0x01;
    buf[97] = 0xe0;

    const dims = findTkhdInPayload(buf[0..trak_size]) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 640), dims.width);
    try std.testing.expectEqual(@as(u32, 480), dims.height);
}

test "parse MP4 tkhd version 1 payload (corrected)" {
    var buf = [_]u8{0} ** 200;

    // trak box: size 112, type "trak"
    const trak_size: u32 = 112;
    buf[0] = @intCast(trak_size >> 24);
    buf[1] = @intCast((trak_size >> 16) & 0xff);
    buf[2] = @intCast((trak_size >> 8) & 0xff);
    buf[3] = @intCast(trak_size & 0xff);
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    // tkhd box: size 104, type "tkhd"
    const tkhd_size: u32 = 104;
    buf[8] = @intCast(tkhd_size >> 24);
    buf[9] = @intCast((tkhd_size >> 16) & 0xff);
    buf[10] = @intCast((tkhd_size >> 8) & 0xff);
    buf[11] = @intCast(tkhd_size & 0xff);
    buf[12] = 't';
    buf[13] = 'k';
    buf[14] = 'h';
    buf[15] = 'd';

    // version = 1 (offset 16)
    buf[16] = 1;

    // For v1: width at offset 88 from payload start = 16 + 88 = 104
    const w_off: usize = 16 + 88;
    buf[w_off] = 0x07;
    buf[w_off + 1] = 0xd0; // 2000

    // height at offset 92 from payload start = 16 + 92 = 108
    const h_off: usize = 16 + 92;
    buf[h_off] = 0x03;
    buf[h_off + 1] = 0xe8; // 1000

    const dims = findTkhdInPayload(buf[0..trak_size]) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 2000), dims.width);
    try std.testing.expectEqual(@as(u32, 1000), dims.height);
}

test "parse MP4 tkhd version 0 payload with nested containers" {
    var buf = [_]u8{0} ** 200;

    // moov box: size 132
    const moov_size: u32 = 132;
    buf[0] = @intCast(moov_size >> 24);
    buf[1] = @intCast((moov_size >> 16) & 0xff);
    buf[2] = @intCast((moov_size >> 8) & 0xff);
    buf[3] = @intCast(moov_size & 0xff);
    buf[4] = 'm';
    buf[5] = 'o';
    buf[6] = 'o';
    buf[7] = 'v';

    // trak box: size 124
    const trak_size: u32 = 124;
    buf[8] = @intCast(trak_size >> 24);
    buf[9] = @intCast((trak_size >> 16) & 0xff);
    buf[10] = @intCast((trak_size >> 8) & 0xff);
    buf[11] = @intCast(trak_size & 0xff);
    buf[12] = 't';
    buf[13] = 'r';
    buf[14] = 'a';
    buf[15] = 'k';

    // mdia box: size 116
    const mdia_size: u32 = 116;
    buf[16] = @intCast(mdia_size >> 24);
    buf[17] = @intCast((mdia_size >> 16) & 0xff);
    buf[18] = @intCast((mdia_size >> 8) & 0xff);
    buf[19] = @intCast(mdia_size & 0xff);
    buf[20] = 'm';
    buf[21] = 'd';
    buf[22] = 'i';
    buf[23] = 'a';

    // minf box: size 108
    const minf_size: u32 = 108;
    buf[24] = @intCast(minf_size >> 24);
    buf[25] = @intCast((minf_size >> 16) & 0xff);
    buf[26] = @intCast((minf_size >> 8) & 0xff);
    buf[27] = @intCast(minf_size & 0xff);
    buf[28] = 'm';
    buf[29] = 'i';
    buf[30] = 'n';
    buf[31] = 'f';

    // stbl box: size 100
    const stbl_size: u32 = 100;
    buf[32] = @intCast(stbl_size >> 24);
    buf[33] = @intCast((stbl_size >> 16) & 0xff);
    buf[34] = @intCast((stbl_size >> 8) & 0xff);
    buf[35] = @intCast(stbl_size & 0xff);
    buf[36] = 's';
    buf[37] = 't';
    buf[38] = 'b';
    buf[39] = 'l';

    // tkhd box: size 92
    const tkhd_size: u32 = 92;
    buf[40] = @intCast(tkhd_size >> 24);
    buf[41] = @intCast((tkhd_size >> 16) & 0xff);
    buf[42] = @intCast((tkhd_size >> 8) & 0xff);
    buf[43] = @intCast(tkhd_size & 0xff);
    buf[44] = 't';
    buf[45] = 'k';
    buf[46] = 'h';
    buf[47] = 'd';

    // tkhd payload starts at offset 48
    buf[48] = 0; // version 0

    // width: 1280 (offset 48 + 76 = 124)
    buf[124] = 0x05;
    buf[125] = 0x00;

    // height: 720 (offset 48 + 80 = 128)
    buf[128] = 0x02;
    buf[129] = 0xd0;
    const dims = findTkhdInPayload(buf[8..moov_size]) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 1280), dims.width);
    try std.testing.expectEqual(@as(u32, 720), dims.height);
}

test "parse MP4 tkhd returns null for unknown version" {
    var buf = [_]u8{0} ** 100;

    // trak box header
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 92;
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    // tkhd box header
    buf[8] = 0;
    buf[9] = 0;
    buf[10] = 0;
    buf[11] = 84;
    buf[12] = 't';
    buf[13] = 'k';
    buf[14] = 'h';
    buf[15] = 'd';

    // version = 99 (invalid)
    buf[16] = 99;

    const result = findTkhdInPayload(&buf);
    try std.testing.expectEqual(null, result);
}

test "parse MP4 tkhd returns null for payload too short" {
    var buf = [_]u8{0} ** 20;
    // trak box header
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 20;
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    // tkhd box header
    buf[8] = 0;
    buf[9] = 0;
    buf[10] = 0;
    buf[11] = 20;
    buf[12] = 't';
    buf[13] = 'k';
    buf[14] = 'h';
    buf[15] = 'd';

    const result = findTkhdInPayload(&buf);
    try std.testing.expectEqual(null, result);
}

test "parse MP4 tkhd returns null for version 0 with truncated payload" {
    var buf = [_]u8{0} ** 50;

    // trak box header
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 54;
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    // tkhd box header (size 54) - v0 needs 92 bytes (payload 84)
    buf[8] = 0;
    buf[9] = 0;
    buf[10] = 0;
    buf[11] = 54;
    buf[12] = 't';
    buf[13] = 'k';
    buf[14] = 'h';
    buf[15] = 'd';

    buf[16] = 0; // version 0

    const result = findTkhdInPayload(&buf);
    try std.testing.expectEqual(null, result);
}

test "parse MP4 tkhd returns null for version 1 with truncated payload" {
    var buf = [_]u8{0} ** 50;

    // trak box header
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 66;
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    // tkhd box header (size 66) - v1 needs 104 bytes (payload 96)
    buf[8] = 0;
    buf[9] = 0;
    buf[10] = 0;
    buf[11] = 66;
    buf[12] = 't';
    buf[13] = 'k';
    buf[14] = 'h';
    buf[15] = 'd';

    buf[16] = 1; // version 1

    const result = findTkhdInPayload(&buf);
    try std.testing.expectEqual(null, result);
}

test "parse MP4 tkhd returns null for zero dimensions" {
    var buf = [_]u8{0} ** 120;

    // trak box header: size 100
    const trak_size: u32 = 100;
    buf[0] = @intCast(trak_size >> 24);
    buf[1] = @intCast((trak_size >> 16) & 0xff);
    buf[2] = @intCast((trak_size >> 8) & 0xff);
    buf[3] = @intCast(trak_size & 0xff);
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    // tkhd box header: size 92
    const tkhd_size: u32 = 92;
    buf[8] = @intCast(tkhd_size >> 24);
    buf[9] = @intCast((tkhd_size >> 16) & 0xff);
    buf[10] = @intCast((tkhd_size >> 8) & 0xff);
    buf[11] = @intCast(tkhd_size & 0xff);
    buf[12] = 't';
    buf[13] = 'k';
    buf[14] = 'h';
    buf[15] = 'd';

    // version = 0
    buf[16] = 0;

    // width and height default to 0

    const result = findTkhdInPayload(buf[0..trak_size]);
    try std.testing.expectEqual(null, result);
}

test "parse MP4 tkhd skips non-tkhd boxes correctly" {
    var buf = [_]u8{0} ** 200;

    // trak box header: size 124
    const trak_size: u32 = 124;
    buf[0] = @intCast(trak_size >> 24);
    buf[1] = @intCast((trak_size >> 16) & 0xff);
    buf[2] = @intCast((trak_size >> 8) & 0xff);
    buf[3] = @intCast(trak_size & 0xff);
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    // First box inside trak: some random box (not a container), size 24
    const rand_size: u32 = 24;
    buf[8] = @intCast(rand_size >> 24);
    buf[9] = @intCast((rand_size >> 16) & 0xff);
    buf[10] = @intCast((rand_size >> 8) & 0xff);
    buf[11] = @intCast(rand_size & 0xff);
    buf[12] = 'x';
    buf[13] = 'y';
    buf[14] = 'z';
    buf[15] = ' ';

    // Second box: tkhd with valid data, size 92
    const tkhd_size: u32 = 92;
    const tkhd_off: usize = 8 + 24;
    buf[tkhd_off] = @intCast(tkhd_size >> 24);
    buf[tkhd_off + 1] = @intCast((tkhd_size >> 16) & 0xff);
    buf[tkhd_off + 2] = @intCast((tkhd_size >> 8) & 0xff);
    buf[tkhd_off + 3] = @intCast(tkhd_size & 0xff);
    buf[tkhd_off + 4] = 't';
    buf[tkhd_off + 5] = 'k';
    buf[tkhd_off + 6] = 'h';
    buf[tkhd_off + 7] = 'd';

    buf[tkhd_off + 8] = 0; // version 0

    const w_off = tkhd_off + 8 + 76;
    buf[w_off] = 0x01;
    buf[w_off + 1] = 0x00; // 256

    const h_off = tkhd_off + 8 + 80;
    buf[h_off] = 0x00;
    buf[h_off + 1] = 0xfc; // 252

    const dims = findTkhdInPayload(buf[0..trak_size]) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 256), dims.width);
    try std.testing.expectEqual(@as(u32, 252), dims.height);
}

test "parse MP4 tkhd handles deeply nested containers" {
    var buf = [_]u8{0} ** 500;

    // Outer container: trak, size 124
    const trak_size: u32 = 124;
    buf[0] = @intCast(trak_size >> 24);
    buf[1] = @intCast((trak_size >> 16) & 0xff);
    buf[2] = @intCast((trak_size >> 8) & 0xff);
    buf[3] = @intCast(trak_size & 0xff);
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    // Inner container: mdia, size 116
    const mdia_size: u32 = 116;
    const mdia_off: usize = 8;
    buf[mdia_off] = @intCast(mdia_size >> 24);
    buf[mdia_off + 1] = @intCast((mdia_size >> 16) & 0xff);
    buf[mdia_off + 2] = @intCast((mdia_size >> 8) & 0xff);
    buf[mdia_off + 3] = @intCast(mdia_size & 0xff);
    buf[mdia_off + 4] = 'm';
    buf[mdia_off + 5] = 'd';
    buf[mdia_off + 6] = 'i';
    buf[mdia_off + 7] = 'a';

    // Deep container: minf, size 108
    const minf_size: u32 = 108;
    const minf_off = mdia_off + 8;
    buf[minf_off] = @intCast(minf_size >> 24);
    buf[minf_off + 1] = @intCast((minf_size >> 16) & 0xff);
    buf[minf_off + 2] = @intCast((minf_size >> 8) & 0xff);
    buf[minf_off + 3] = @intCast(minf_size & 0xff);
    buf[minf_off + 4] = 'm';
    buf[minf_off + 5] = 'i';
    buf[minf_off + 6] = 'n';
    buf[minf_off + 7] = 'f';

    // Leaf container: stbl, size 100
    const stbl_size: u32 = 100;
    const stbl_off = minf_off + 8;
    buf[stbl_off] = @intCast(stbl_size >> 24);
    buf[stbl_off + 1] = @intCast((stbl_size >> 16) & 0xff);
    buf[stbl_off + 2] = @intCast((stbl_size >> 8) & 0xff);
    buf[stbl_off + 3] = @intCast(stbl_size & 0xff);
    buf[stbl_off + 4] = 's';
    buf[stbl_off + 5] = 't';
    buf[stbl_off + 6] = 'b';
    buf[stbl_off + 7] = 'l';

    // Finally: tkhd, size 92
    const tkhd_size: u32 = 92;
    const tkhd_off = stbl_off + 8;
    buf[tkhd_off] = @intCast(tkhd_size >> 24);
    buf[tkhd_off + 1] = @intCast((tkhd_size >> 16) & 0xff);
    buf[tkhd_off + 2] = @intCast((tkhd_size >> 8) & 0xff);
    buf[tkhd_off + 3] = @intCast(tkhd_size & 0xff);
    buf[tkhd_off + 4] = 't';
    buf[tkhd_off + 5] = 'k';
    buf[tkhd_off + 6] = 'h';
    buf[tkhd_off + 7] = 'd';

    buf[tkhd_off + 8] = 0; // version 0

    const w_off = tkhd_off + 8 + 76;
    buf[w_off] = 0x0a;
    buf[w_off + 1] = 0xc8; // 2760

    const h_off = tkhd_off + 8 + 80;
    buf[h_off] = 0x04;
    buf[h_off + 1] = 0xd2; // 1234

    const dims = findTkhdInPayload(buf[0..trak_size]) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 2760), dims.width);
    try std.testing.expectEqual(@as(u32, 1234), dims.height);
}

test "parse MP4 tkhd handles invalid box size returns null" {
    var buf = [_]u8{0} ** 50;

    // Box with size < 8 (invalid)
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 4; // size too small
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    const result = findTkhdInPayload(&buf);
    try std.testing.expectEqual(null, result);
}

test "parse MP4 tkhd handles box size exceeding payload returns null" {
    var buf = [_]u8{0} ** 50;

    // Box claiming to be larger than available data
    const big_size: u32 = 1000;
    buf[0] = @intCast(big_size >> 24);
    buf[1] = @intCast((big_size >> 16) & 0xff);
    buf[2] = @intCast((big_size >> 8) & 0xff);
    buf[3] = @intCast(big_size & 0xff);
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    const result = findTkhdInPayload(&buf);
    try std.testing.expectEqual(null, result);
}

test "parse MP4 tkhd handles empty payload" {
    const buf: []const u8 = &[_]u8{};
    const result = findTkhdInPayload(buf);
    try std.testing.expectEqual(null, result);
}

test "parse MP4 tkhd handles single byte payload" {
    const buf = [_]u8{0x42};
    const result = findTkhdInPayload(&buf);
    try std.testing.expectEqual(null, result);
}

test "parse MP4 tkhd version 0 with negative height (top-down bitmap style)" {
    var buf = [_]u8{0} ** 120;

    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 100;
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    buf[8] = 0;
    buf[9] = 0;
    buf[10] = 0;
    buf[11] = 92;
    buf[12] = 't';
    buf[13] = 'k';
    buf[14] = 'h';
    buf[15] = 'd';

    buf[16] = 0; // version 0

    // width: 0x7FFF (32767)
    const w_off: usize = 16 + 76;
    buf[w_off] = 0x7f;
    buf[w_off + 1] = 0xff;

    // height: 0x0BB8 (3000)
    const h_off: usize = 16 + 80;
    buf[h_off] = 0x0b;
    buf[h_off + 1] = 0xb8;

    const dims = findTkhdInPayload(buf[0..100]) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 32767), dims.width);
    try std.testing.expectEqual(@as(u32, 3000), dims.height);
}

test "parse MP4 tkhd handles multiple sibling boxes finds correct tkhd" {
    var buf = [_]u8{0} ** 200;

    // First sibling: some non-tkhd box (size 32)
    const sib1_size: u32 = 32;
    buf[0] = @intCast(sib1_size >> 24);
    buf[1] = @intCast((sib1_size >> 16) & 0xff);
    buf[2] = @intCast((sib1_size >> 8) & 0xff);
    buf[3] = @intCast(sib1_size & 0xff);
    buf[4] = 'm';
    buf[5] = 'd';
    buf[6] = 'h';
    buf[7] = 'r';

    // Second sibling: tkhd with dimensions (size 92)
    const tkhd_size: u32 = 92;
    const tkhd_off: usize = 32;
    buf[tkhd_off] = @intCast(tkhd_size >> 24);
    buf[tkhd_off + 1] = @intCast((tkhd_size >> 16) & 0xff);
    buf[tkhd_off + 2] = @intCast((tkhd_size >> 8) & 0xff);
    buf[tkhd_off + 3] = @intCast(tkhd_size & 0xff);
    buf[tkhd_off + 4] = 't';
    buf[tkhd_off + 5] = 'k';
    buf[tkhd_off + 6] = 'h';
    buf[tkhd_off + 7] = 'd';

    buf[tkhd_off + 8] = 0; // version 0

    const w_off = tkhd_off + 8 + 76;
    buf[w_off] = 0x03;
    buf[w_off + 1] = 0xc0; // 960

    const h_off = tkhd_off + 8 + 80;
    buf[h_off] = 0x02;
    buf[h_off + 1] = 0x58; // 600

    const dims = findTkhdInPayload(buf[0 .. 32 + tkhd_size]) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 960), dims.width);
    try std.testing.expectEqual(@as(u32, 600), dims.height);
}

test "formatEpoch civil time formatting" {
    const allocator = std.testing.allocator;
    const epoch_secs: u64 = 1718300000; // 2024-06-13 17:33:20
    const str = try utils.formatEpoch(allocator, epoch_secs);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("2024-06-13 17:33:20", str);
}

test "parseMvhd version 0 duration and creation date" {
    const allocator = std.testing.allocator;
    var info = VideoInfo{
        .format = "mp4",
        .width = 0,
        .height = 0,
    };
    defer info.deinit(allocator);

    var payload = [_]u8{0} ** 36;
    payload[0] = 0; // version 0
    // creation time: 2082844800 (1970-01-01 00:00:00 Unix epoch) + 1718300000 = 3801144800
    // 3801144800 in hex is 0xE28EB9E0
    payload[4] = 0xe2;
    payload[5] = 0x8e;
    payload[6] = 0xb9;
    payload[7] = 0xe0;

    // timescale: 1000 -> 0x000003E8
    payload[12] = 0;
    payload[13] = 0;
    payload[14] = 0x03;
    payload[15] = 0xe8;

    // duration: 3550053 -> 0x00362C65
    payload[16] = 0x00;
    payload[17] = 0x36;
    payload[18] = 0x2c;
    payload[19] = 0x65;

    try parseMvhd(allocator, &payload, &info);
    try std.testing.expectEqual(@as(f64, 3550.309), info.duration_sec.?);
    try std.testing.expectEqualStrings("2024-06-12 02:35:12", info.create_time.?);
}

test "parseTkhd rotation matrices" {
    // 1. Normal (Identity matrix)
    {
        var payload = [_]u8{0} ** 84;
        payload[0] = 0; // version 0
        // matrix:
        // a = 0x00010000 (offset 40)
        payload[40] = 0x00;
        payload[41] = 0x01;
        payload[42] = 0x00;
        payload[43] = 0x00;
        // d = 0x00010000 (offset 56)
        payload[56] = 0x00;
        payload[57] = 0x01;
        payload[58] = 0x00;
        payload[59] = 0x00;

        const dims = parseTkhd(&payload) orelse return error.TestFailed;
        try std.testing.expectEqual(@as(u16, 1), dims.orientation);
    }

    // 2. 90 degrees CW rotation
    {
        var payload = [_]u8{0} ** 84;
        payload[0] = 0; // version 0
        // b = 0x00010000 (offset 44)
        payload[44] = 0x00;
        payload[45] = 0x01;
        payload[46] = 0x00;
        payload[47] = 0x00;
        // c = -0x00010000 (offset 52) -> 0xFFFF0000
        payload[52] = 0xff;
        payload[53] = 0xff;
        payload[54] = 0x00;
        payload[55] = 0x00;

        const dims = parseTkhd(&payload) orelse return error.TestFailed;
        try std.testing.expectEqual(@as(u16, 6), dims.orientation);
    }

    // 3. 180 degrees rotation
    {
        var payload = [_]u8{0} ** 84;
        payload[0] = 0; // version 0
        // a = -0x00010000 (offset 40) -> 0xFFFF0000
        payload[40] = 0xff;
        payload[41] = 0xff;
        payload[42] = 0x00;
        payload[43] = 0x00;
        // d = -0x00010000 (offset 56) -> 0xFFFF0000
        payload[56] = 0xff;
        payload[57] = 0xff;
        payload[58] = 0x00;
        payload[59] = 0x00;

        const dims = parseTkhd(&payload) orelse return error.TestFailed;
        try std.testing.expectEqual(@as(u16, 3), dims.orientation);
    }

    // 4. 270 degrees CW (90 CCW) rotation
    {
        var payload = [_]u8{0} ** 84;
        payload[0] = 0; // version 0
        // b = -0x00010000 (offset 44) -> 0xFFFF0000
        payload[44] = 0xff;
        payload[45] = 0xff;
        payload[46] = 0x00;
        payload[47] = 0x00;
        // c = 0x00010000 (offset 52)
        payload[52] = 0x00;
        payload[53] = 0x01;
        payload[54] = 0x00;
        payload[55] = 0x00;

        const dims = parseTkhd(&payload) orelse return error.TestFailed;
        try std.testing.expectEqual(@as(u16, 8), dims.orientation);
    }
}
