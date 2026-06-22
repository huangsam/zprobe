const std = @import("std");
const utils = @import("../../core/utils.zig");
const ByteReader = @import("../../core/byte_reader.zig").ByteReader;
const common = @import("common.zig");
const VideoInfo = common.VideoInfo;
const test_utils = @import("../../core/test_utils.zig");

/// Dimensions and orientation extracted from a video track.
pub const Dims = struct {
    /// Width in pixels.
    width: u32,
    /// Height in pixels.
    height: u32,
    /// Orientation/rotation mapping (1: 0°, 3: 180°, 6: 90° CW, 8: 270° CW).
    orientation: u16 = 1,
};

/// Parse a `tkhd` (Track Header) box payload.
pub fn parseTkhd(reader: *ByteReader) ?Dims {
    const version = reader.readInt(u8) catch return null;
    reader.skip(3) catch return null; // flags

    if (version == 0) {
        reader.skip(20) catch return null;
    } else if (version == 1) {
        reader.skip(32) catch return null;
    } else {
        return null;
    }

    reader.skip(8) catch return null; // reserved2
    reader.skip(8) catch return null; // layer, alternate_group, volume, reserved3

    // Read the 3x3 transformation matrix from the tkhd box.
    // Matrix format: [a, b, u] [c, d, v] [x, y, w_coeff]
    // Only a, b, c, d are relevant for rotation; others handle translation/scaling.
    const a = reader.readInt(i32) catch return null;
    const b = reader.readInt(i32) catch return null;
    const u = reader.readInt(i32) catch return null;
    const c = reader.readInt(i32) catch return null;
    const d = reader.readInt(i32) catch return null;
    const v = reader.readInt(i32) catch return null;
    const x = reader.readInt(i32) catch return null;
    const y = reader.readInt(i32) catch return null;
    const w_coeff = reader.readInt(i32) catch return null;
    _ = u;
    _ = v;
    _ = x;
    _ = y;
    _ = w_coeff;

    const width_int = reader.readInt(u16) catch return null;
    reader.skip(2) catch return null;
    const height_int = reader.readInt(u16) catch return null;
    reader.skip(2) catch return null;

    // Decode orientation from the transformation matrix.
    // Matrix values are fixed-point (16.16 format): 0x00010000 = 1.0, -0x00010000 = -1.0.
    // Orientation values per EXIF spec: 1=normal, 3=180°, 6=90°CW, 8=270°CW.
    var orientation: u16 = 1;
    if (b == 0x00010000 and c == -0x00010000) {
        // b=1, c=-1: 90° clockwise rotation
        orientation = 6;
    } else if (a == -0x00010000 and d == -0x00010000) {
        // a=-1, d=-1: 180° rotation
        orientation = 3;
    } else if (b == -0x00010000 and c == 0x00010000) {
        // b=-1, c=1: 270° clockwise rotation (90° counter-clockwise)
        orientation = 8;
    }

    return .{ .width = width_int, .height = height_int, .orientation = orientation };
}

/// Recursively search for the `tkhd` box within nested container boxes.
pub fn findTkhdInPayload(payload: []const u8) ?Dims {
    var reader = ByteReader.init(payload, .big);
    return findTkhdInReader(&reader, 0);
}

/// Scan boxes in a ByteReader recursively to locate and parse the `tkhd` track header box.
/// Depth limit of 16 prevents stack exhaustion on pathological/malformed files with deep nesting.
pub fn findTkhdInReader(reader: *ByteReader, depth: usize) ?Dims {
    if (depth > 16) return null;
    while (reader.remaining() >= 8) {
        const box_size_32 = reader.readInt(u32) catch return null;
        const box_type = reader.peek(4) catch return null;
        reader.skip(4) catch return null;

        var header_len: u64 = 8;
        var box_size: u64 = box_size_32;

        if (box_size_32 == 1) {
            if (reader.remaining() < 8) return null;
            box_size = reader.readInt(u64) catch return null;
            header_len = 16;
        } else if (box_size_32 == 0) {
            box_size = reader.remaining() + 8;
        }

        if (box_size < header_len) return null;

        const payload_size = box_size - header_len;
        if (payload_size > reader.remaining()) return null;

        var sub = reader.subReader(payload_size) catch return null;

        if (std.mem.eql(u8, box_type, "tkhd")) {
            if (parseTkhd(&sub)) |dims| {
                if (dims.width > 0 and dims.height > 0) {
                    return dims;
                }
            }
        } else if (std.mem.eql(u8, box_type, "trak") or
            std.mem.eql(u8, box_type, "mdia") or
            std.mem.eql(u8, box_type, "minf") or
            std.mem.eql(u8, box_type, "stbl"))
        {
            if (findTkhdInReader(&sub, depth + 1)) |dims| {
                return dims;
            }
        }
    }
    return null;
}

/// Parse the `mvhd` (Movie Header) payload to extract video duration and creation date.
pub fn parseMvhd(allocator: std.mem.Allocator, payload: []const u8, info: *VideoInfo) !void {
    var reader = ByteReader.init(payload, .big);
    try parseMvhdInReader(allocator, &reader, info);
}

/// Read details from a `mvhd` box payload via a ByteReader, computing duration in seconds
/// and formatting the creation epoch.
pub fn parseMvhdInReader(allocator: std.mem.Allocator, reader: *ByteReader, info: *VideoInfo) !void {
    const version = try reader.readInt(u8);
    try reader.skip(3); // flags

    var creation_time: u64 = 0;
    var timescale: u32 = 0;
    var duration: u64 = 0;

    if (version == 0) {
        creation_time = try reader.readInt(u32);
        _ = try reader.readInt(u32); // modification_time
        timescale = try reader.readInt(u32);
        duration = try reader.readInt(u32);
    } else if (version == 1) {
        creation_time = try reader.readInt(u64);
        _ = try reader.readInt(u64); // modification_time
        timescale = try reader.readInt(u32);
        duration = try reader.readInt(u64);
    } else {
        return;
    }

    if (timescale > 0) {
        info.duration_sec = @as(f64, @floatFromInt(duration)) / @as(f64, @floatFromInt(timescale));
    }

    if (creation_time >= 2082844800) {
        const unix_secs = creation_time - 2082844800;
        info.create_time = utils.formatEpoch(allocator, unix_secs) catch null;
    }
}

/// Walk the ISO base media file (MP4/MOV) structure in the specified range to locate
/// `mvhd` (Movie Header) and `tkhd` (Track Header) boxes, extracting duration and layout info.
pub fn findTkhdAndMvhdInFile(allocator: std.mem.Allocator, file: anytype, io: anytype, start_offset: u64, end_offset: u64, info: *VideoInfo, depth: usize) !void {
    if (depth > 16) return error.Mp4TooDeep;
    var offset = start_offset;
    while (offset + 8 <= end_offset) {
        var header_buf: [8]u8 = undefined;
        const h_read = try std.Io.File.readPositionalAll(file, io, &header_buf, offset);
        if (h_read < 8) return error.InvalidMp4;

        const box_size = @as(u64, header_buf[0]) << 24 |
            @as(u64, header_buf[1]) << 16 |
            @as(u64, header_buf[2]) << 8 |
            @as(u64, header_buf[3]);

        const box_type = header_buf[4..8];

        var header_len: u64 = 8;
        var real_size = box_size;

        if (box_size == 1) {
            if (offset + 16 > end_offset) return error.InvalidMp4;
            var ext_size_buf: [8]u8 = undefined;
            const ext_read = try std.Io.File.readPositionalAll(file, io, &ext_size_buf, offset + 8);
            if (ext_read < 8) return error.InvalidMp4;
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

        // Use subtraction to avoid integer overflow in bounds check
        if (real_size < header_len or real_size > end_offset - offset) return error.InvalidMp4;

        if (std.mem.eql(u8, box_type, "mvhd")) {
            const payload_len = real_size - header_len;
            var mvhd_buf: [36]u8 = undefined;
            const read_len = @min(payload_len, mvhd_buf.len);
            const read = try std.Io.File.readPositionalAll(file, io, mvhd_buf[0..read_len], offset + header_len);
            if (read == read_len) {
                try parseMvhd(allocator, mvhd_buf[0..read], info);
            }
        } else if (std.mem.eql(u8, box_type, "tkhd")) {
            const payload_len = real_size - header_len;
            var tkhd_buf: [96]u8 = undefined;
            const read_len = @min(payload_len, tkhd_buf.len);
            const read = try std.Io.File.readPositionalAll(file, io, tkhd_buf[0..read_len], offset + header_len);
            if (read == read_len) {
                var reader = ByteReader.init(tkhd_buf[0..read], .big);
                if (parseTkhd(&reader)) |dims| {
                    if (dims.width > 0 and dims.height > 0) {
                        info.width = dims.width;
                        info.height = dims.height;
                        info.orientation = dims.orientation;
                    }
                }
            }
        } else if (std.mem.eql(u8, box_type, "trak") or
            std.mem.eql(u8, box_type, "mdia") or
            std.mem.eql(u8, box_type, "minf") or
            std.mem.eql(u8, box_type, "stbl"))
        {
            try findTkhdAndMvhdInFile(allocator, file, io, offset + header_len, offset + real_size, info, depth + 1);
        }

        offset += real_size;
    }
}

test "parse MP4 moov/trak/tkhd version 0 payload" {
    var buf = [_]u8{0} ** 120;

    const trak_size: u32 = 100;
    buf[0] = @intCast(trak_size >> 24);
    buf[1] = @intCast((trak_size >> 16) & 0xff);
    buf[2] = @intCast((trak_size >> 8) & 0xff);
    buf[3] = @intCast(trak_size & 0xff);
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    const tkhd_size: u32 = 92;
    buf[8] = @intCast(tkhd_size >> 24);
    buf[9] = @intCast((tkhd_size >> 16) & 0xff);
    buf[10] = @intCast((tkhd_size >> 8) & 0xff);
    buf[11] = @intCast(tkhd_size & 0xff);
    buf[12] = 't';
    buf[13] = 'k';
    buf[14] = 'h';
    buf[15] = 'd';

    buf[16] = 0;

    buf[92] = 0x02;
    buf[93] = 0x80;

    buf[96] = 0x01;
    buf[97] = 0xe0;

    const dims = findTkhdInPayload(buf[0..trak_size]) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 640), dims.width);
    try std.testing.expectEqual(@as(u32, 480), dims.height);
}

test "parse MP4 tkhd version 1 payload (corrected)" {
    var buf = [_]u8{0} ** 200;

    const trak_size: u32 = 112;
    buf[0] = @intCast(trak_size >> 24);
    buf[1] = @intCast((trak_size >> 16) & 0xff);
    buf[2] = @intCast((trak_size >> 8) & 0xff);
    buf[3] = @intCast(trak_size & 0xff);
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    const tkhd_size: u32 = 104;
    buf[8] = @intCast(tkhd_size >> 24);
    buf[9] = @intCast((tkhd_size >> 16) & 0xff);
    buf[10] = @intCast((tkhd_size >> 8) & 0xff);
    buf[11] = @intCast(tkhd_size & 0xff);
    buf[12] = 't';
    buf[13] = 'k';
    buf[14] = 'h';
    buf[15] = 'd';

    buf[16] = 1;

    const w_off: usize = 16 + 88;
    buf[w_off] = 0x07;
    buf[w_off + 1] = 0xd0;

    const h_off: usize = 16 + 92;
    buf[h_off] = 0x03;
    buf[h_off + 1] = 0xe8;

    const dims = findTkhdInPayload(buf[0..trak_size]) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 2000), dims.width);
    try std.testing.expectEqual(@as(u32, 1000), dims.height);
}

test "parse MP4 tkhd version 0 payload with nested containers" {
    var buf = [_]u8{0} ** 200;

    const moov_size: u32 = 132;
    buf[0] = @intCast(moov_size >> 24);
    buf[1] = @intCast((moov_size >> 16) & 0xff);
    buf[2] = @intCast((moov_size >> 8) & 0xff);
    buf[3] = @intCast(moov_size & 0xff);
    buf[4] = 'm';
    buf[5] = 'o';
    buf[6] = 'o';
    buf[7] = 'v';

    const trak_size: u32 = 124;
    buf[8] = @intCast(trak_size >> 24);
    buf[9] = @intCast((trak_size >> 16) & 0xff);
    buf[10] = @intCast((trak_size >> 8) & 0xff);
    buf[11] = @intCast(trak_size & 0xff);
    buf[12] = 't';
    buf[13] = 'r';
    buf[14] = 'a';
    buf[15] = 'k';

    const mdia_size: u32 = 116;
    buf[16] = @intCast(mdia_size >> 24);
    buf[17] = @intCast((mdia_size >> 16) & 0xff);
    buf[18] = @intCast((mdia_size >> 8) & 0xff);
    buf[19] = @intCast(mdia_size & 0xff);
    buf[20] = 'm';
    buf[21] = 'd';
    buf[22] = 'i';
    buf[23] = 'a';

    const minf_size: u32 = 108;
    buf[24] = @intCast(minf_size >> 24);
    buf[25] = @intCast((minf_size >> 16) & 0xff);
    buf[26] = @intCast((minf_size >> 8) & 0xff);
    buf[27] = @intCast(minf_size & 0xff);
    buf[28] = 'm';
    buf[29] = 'i';
    buf[30] = 'n';
    buf[31] = 'f';

    const stbl_size: u32 = 100;
    buf[32] = @intCast(stbl_size >> 24);
    buf[33] = @intCast((stbl_size >> 16) & 0xff);
    buf[34] = @intCast((stbl_size >> 8) & 0xff);
    buf[35] = @intCast(stbl_size & 0xff);
    buf[36] = 's';
    buf[37] = 't';
    buf[38] = 'b';
    buf[39] = 'l';

    const tkhd_size: u32 = 92;
    buf[40] = @intCast(tkhd_size >> 24);
    buf[41] = @intCast((tkhd_size >> 16) & 0xff);
    buf[42] = @intCast((tkhd_size >> 8) & 0xff);
    buf[43] = @intCast(tkhd_size & 0xff);
    buf[44] = 't';
    buf[45] = 'k';
    buf[46] = 'h';
    buf[47] = 'd';

    buf[48] = 0;

    buf[124] = 0x05;
    buf[125] = 0x00;

    buf[128] = 0x02;
    buf[129] = 0xd0;
    const dims = findTkhdInPayload(buf[8..moov_size]) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 1280), dims.width);
    try std.testing.expectEqual(@as(u32, 720), dims.height);
}

test "parse MP4 tkhd returns null for unknown version" {
    var buf = [_]u8{0} ** 100;

    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 92;
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    buf[8] = 0;
    buf[9] = 0;
    buf[10] = 0;
    buf[11] = 84;
    buf[12] = 't';
    buf[13] = 'k';
    buf[14] = 'h';
    buf[15] = 'd';

    buf[16] = 99;

    const result = findTkhdInPayload(&buf);
    try std.testing.expectEqual(null, result);
}

test "parse MP4 tkhd returns null for payload too short" {
    var buf = [_]u8{0} ** 20;
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 20;
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

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

    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 54;
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    buf[8] = 0;
    buf[9] = 0;
    buf[10] = 0;
    buf[11] = 54;
    buf[12] = 't';
    buf[13] = 'k';
    buf[14] = 'h';
    buf[15] = 'd';

    buf[16] = 0;

    const result = findTkhdInPayload(&buf);
    try std.testing.expectEqual(null, result);
}

test "parse MP4 tkhd returns null for version 1 with truncated payload" {
    var buf = [_]u8{0} ** 50;

    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 66;
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    buf[8] = 0;
    buf[9] = 0;
    buf[10] = 0;
    buf[11] = 66;
    buf[12] = 't';
    buf[13] = 'k';
    buf[14] = 'h';
    buf[15] = 'd';

    buf[16] = 1;

    const result = findTkhdInPayload(&buf);
    try std.testing.expectEqual(null, result);
}

test "parse MP4 tkhd returns null for zero dimensions" {
    var buf = [_]u8{0} ** 120;

    const trak_size: u32 = 100;
    buf[0] = @intCast(trak_size >> 24);
    buf[1] = @intCast((trak_size >> 16) & 0xff);
    buf[2] = @intCast((trak_size >> 8) & 0xff);
    buf[3] = @intCast(trak_size & 0xff);
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    const tkhd_size: u32 = 92;
    buf[8] = @intCast(tkhd_size >> 24);
    buf[9] = @intCast((tkhd_size >> 16) & 0xff);
    buf[10] = @intCast((tkhd_size >> 8) & 0xff);
    buf[11] = @intCast(tkhd_size & 0xff);
    buf[12] = 't';
    buf[13] = 'k';
    buf[14] = 'h';
    buf[15] = 'd';

    buf[16] = 0;

    const result = findTkhdInPayload(buf[0..trak_size]);
    try std.testing.expectEqual(null, result);
}

test "parse MP4 tkhd skips non-tkhd boxes correctly" {
    var buf = [_]u8{0} ** 200;

    const trak_size: u32 = 124;
    buf[0] = @intCast(trak_size >> 24);
    buf[1] = @intCast((trak_size >> 16) & 0xff);
    buf[2] = @intCast((trak_size >> 8) & 0xff);
    buf[3] = @intCast(trak_size & 0xff);
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    const rand_size: u32 = 24;
    buf[8] = @intCast(rand_size >> 24);
    buf[9] = @intCast((rand_size >> 16) & 0xff);
    buf[10] = @intCast((rand_size >> 8) & 0xff);
    buf[11] = @intCast(rand_size & 0xff);
    buf[12] = 'x';
    buf[13] = 'y';
    buf[14] = 'z';
    buf[15] = ' ';

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

    buf[tkhd_off + 8] = 0;

    const w_off = tkhd_off + 8 + 76;
    buf[w_off] = 0x01;
    buf[w_off + 1] = 0x00;

    const h_off = tkhd_off + 8 + 80;
    buf[h_off] = 0x00;
    buf[h_off + 1] = 0xfc;

    const dims = findTkhdInPayload(buf[0..trak_size]) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 256), dims.width);
    try std.testing.expectEqual(@as(u32, 252), dims.height);
}

test "parse MP4 tkhd handles deeply nested containers" {
    var buf = [_]u8{0} ** 500;

    const trak_size: u32 = 124;
    buf[0] = @intCast(trak_size >> 24);
    buf[1] = @intCast((trak_size >> 16) & 0xff);
    buf[2] = @intCast((trak_size >> 8) & 0xff);
    buf[3] = @intCast(trak_size & 0xff);
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

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

    buf[tkhd_off + 8] = 0;

    const w_off = tkhd_off + 8 + 76;
    buf[w_off] = 0x0a;
    buf[w_off + 1] = 0xc8;

    const h_off = tkhd_off + 8 + 80;
    buf[h_off] = 0x04;
    buf[h_off + 1] = 0xd2;

    const dims = findTkhdInPayload(buf[0..trak_size]) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 2760), dims.width);
    try std.testing.expectEqual(@as(u32, 1234), dims.height);
}

test "parse MP4 tkhd handles invalid box size returns null" {
    var buf = [_]u8{0} ** 50;

    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 4;
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    const result = findTkhdInPayload(&buf);
    try std.testing.expectEqual(null, result);
}

test "parse MP4 tkhd handles box size exceeding payload returns null" {
    var buf = [_]u8{0} ** 50;

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

    buf[16] = 0;

    const w_off: usize = 16 + 76;
    buf[w_off] = 0x7f;
    buf[w_off + 1] = 0xff;

    const h_off: usize = 16 + 80;
    buf[h_off] = 0x0b;
    buf[h_off + 1] = 0xb8;

    const dims = findTkhdInPayload(buf[0..100]) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 32767), dims.width);
    try std.testing.expectEqual(@as(u32, 3000), dims.height);
}

test "parse MP4 tkhd handles multiple sibling boxes finds correct tkhd" {
    var buf = [_]u8{0} ** 200;

    const sib1_size: u32 = 32;
    buf[0] = @intCast(sib1_size >> 24);
    buf[1] = @intCast((sib1_size >> 16) & 0xff);
    buf[2] = @intCast((sib1_size >> 8) & 0xff);
    buf[3] = @intCast(sib1_size & 0xff);
    buf[4] = 'm';
    buf[5] = 'd';
    buf[6] = 'h';
    buf[7] = 'r';

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

    buf[tkhd_off + 8] = 0;

    const w_off = tkhd_off + 8 + 76;
    buf[w_off] = 0x03;
    buf[w_off + 1] = 0xc0;

    const h_off = tkhd_off + 8 + 80;
    buf[h_off] = 0x02;
    buf[h_off + 1] = 0x58;

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
    payload[4] = 0xe2;
    payload[5] = 0x8e;
    payload[6] = 0xb9;
    payload[7] = 0xe0;

    payload[12] = 0;
    payload[13] = 0;
    payload[14] = 0x03;
    payload[15] = 0xe8;

    payload[16] = 0x00;
    payload[17] = 0x36;
    payload[18] = 0x2c;
    payload[19] = 0x65;

    try parseMvhd(allocator, &payload, &info);
    try std.testing.expectEqual(@as(f64, 3550.309), info.duration_sec.?);
    try std.testing.expectEqualStrings("2024-06-12 02:35:12", info.create_time.?);
}

test "parseTkhd rotation matrices" {
    {
        var payload = [_]u8{0} ** 84;
        payload[0] = 0;
        payload[40] = 0x00;
        payload[41] = 0x01;
        payload[42] = 0x00;
        payload[43] = 0x00;
        payload[56] = 0x00;
        payload[57] = 0x01;
        payload[58] = 0x00;
        payload[59] = 0x00;

        var reader = ByteReader.init(&payload, .big);
        const dims = parseTkhd(&reader) orelse return error.TestFailed;
        try std.testing.expectEqual(@as(u16, 1), dims.orientation);
    }

    {
        var payload = [_]u8{0} ** 84;
        payload[0] = 0;
        payload[44] = 0x00;
        payload[45] = 0x01;
        payload[46] = 0x00;
        payload[47] = 0x00;
        payload[52] = 0xff;
        payload[53] = 0xff;
        payload[54] = 0x00;
        payload[55] = 0x00;

        var reader = ByteReader.init(&payload, .big);
        const dims = parseTkhd(&reader) orelse return error.TestFailed;
        try std.testing.expectEqual(@as(u16, 6), dims.orientation);
    }

    {
        var payload = [_]u8{0} ** 84;
        payload[0] = 0;
        payload[40] = 0xff;
        payload[41] = 0xff;
        payload[42] = 0x00;
        payload[43] = 0x00;
        payload[56] = 0xff;
        payload[57] = 0xff;
        payload[58] = 0x00;
        payload[59] = 0x00;

        var reader = ByteReader.init(&payload, .big);
        const dims = parseTkhd(&reader) orelse return error.TestFailed;
        try std.testing.expectEqual(@as(u16, 3), dims.orientation);
    }

    {
        var payload = [_]u8{0} ** 84;
        payload[0] = 0;
        payload[44] = 0xff;
        payload[45] = 0xff;
        payload[46] = 0x00;
        payload[47] = 0x00;
        payload[52] = 0x00;
        payload[53] = 0x01;
        payload[54] = 0x00;
        payload[55] = 0x00;

        var reader = ByteReader.init(&payload, .big);
        const dims = parseTkhd(&reader) orelse return error.TestFailed;
        try std.testing.expectEqual(@as(u16, 8), dims.orientation);
    }
}

test "findTkhdInPayload deeply nested trak boxes returns null" {
    var buf = [_]u8{0} ** (8 * 18);
    var i: usize = 0;
    while (i < 18) : (i += 1) {
        const offset = i * 8;
        const box_size = @as(u32, @intCast(8 * (18 - i)));
        buf[offset + 0] = @intCast(box_size >> 24);
        buf[offset + 1] = @intCast((box_size >> 16) & 0xff);
        buf[offset + 2] = @intCast((box_size >> 8) & 0xff);
        buf[offset + 3] = @intCast(box_size & 0xff);
        buf[offset + 4] = 't';
        buf[offset + 5] = 'r';
        buf[offset + 6] = 'a';
        buf[offset + 7] = 'k';
    }

    const dims = findTkhdInPayload(&buf);
    try std.testing.expectEqual(null, dims);
}

test "findTkhdAndMvhdInFile deeply nested boxes returns Mp4TooDeep" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;
    const temp_filename = "temp_test_mp4_deep.mp4";

    const file = try std.Io.Dir.createFile(temp_dir, io, temp_filename, .{});
    defer std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(temp_dir, io, temp_filename) catch {};

    // 18 levels of nested trak boxes.
    var buf = [_]u8{0} ** (8 * 18);
    var i: usize = 0;
    while (i < 18) : (i += 1) {
        const offset = i * 8;
        const box_size = @as(u32, @intCast(8 * (18 - i)));
        buf[offset + 0] = @intCast(box_size >> 24);
        buf[offset + 1] = @intCast((box_size >> 16) & 0xff);
        buf[offset + 2] = @intCast((box_size >> 8) & 0xff);
        buf[offset + 3] = @intCast(box_size & 0xff);
        buf[offset + 4] = 't';
        buf[offset + 5] = 'r';
        buf[offset + 6] = 'a';
        buf[offset + 7] = 'k';
    }

    try std.Io.File.writePositionalAll(file, io, &buf, 0);

    const check_file = try std.Io.Dir.openFile(temp_dir, io, temp_filename, .{ .mode = .read_only });
    defer std.Io.File.close(check_file, io);

    var info = VideoInfo{
        .format = "mp4",
        .width = 0,
        .height = 0,
    };
    defer info.deinit(allocator);

    try std.testing.expectError(error.Mp4TooDeep, findTkhdAndMvhdInFile(allocator, check_file, io, 0, buf.len, &info, 0));
}

test "parse MP4 64-bit size box payload in findTkhdInPayload" {
    var buf = [_]u8{0} ** 130;

    // trak box size is 120, represented as 64-bit size box:
    // first 4 bytes = 1
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 1;
    // type = 'trak'
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';
    // 64-bit size = 120
    const trak_size: u64 = 120;
    buf[8] = @intCast(trak_size >> 56);
    buf[9] = @intCast((trak_size >> 48) & 0xff);
    buf[10] = @intCast((trak_size >> 40) & 0xff);
    buf[11] = @intCast((trak_size >> 32) & 0xff);
    buf[12] = @intCast((trak_size >> 24) & 0xff);
    buf[13] = @intCast((trak_size >> 16) & 0xff);
    buf[14] = @intCast((trak_size >> 8) & 0xff);
    buf[15] = @intCast(trak_size & 0xff);

    // tkhd box size is 92 (standard 32-bit size) starting at offset 16
    const tkhd_size: u32 = 92;
    buf[16] = @intCast(tkhd_size >> 24);
    buf[17] = @intCast((tkhd_size >> 16) & 0xff);
    buf[18] = @intCast((tkhd_size >> 8) & 0xff);
    buf[19] = @intCast(tkhd_size & 0xff);
    buf[20] = 't';
    buf[21] = 'k';
    buf[22] = 'h';
    buf[23] = 'd';

    buf[24] = 0; // version 0

    // width = 640, height = 480
    buf[100] = 0x02;
    buf[101] = 0x80;
    buf[104] = 0x01;
    buf[105] = 0xe0;

    const dims = findTkhdInPayload(buf[0..trak_size]) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 640), dims.width);
    try std.testing.expectEqual(@as(u32, 480), dims.height);
}

test "parse MP4 64-bit size box payload truncation in findTkhdAndMvhdInFile" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;
    const temp_filename = "temp_truncated_64bit_nested.mp4";

    const file = try std.Io.Dir.createFile(temp_dir, io, temp_filename, .{});
    defer std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(temp_dir, io, temp_filename) catch {};

    var buf = [_]u8{0} ** 12;
    buf[0] = 0x00;
    buf[1] = 0x00;
    buf[2] = 0x00;
    buf[3] = 0x01;
    buf[4] = 't';
    buf[5] = 'r';
    buf[6] = 'a';
    buf[7] = 'k';

    try std.Io.File.writePositionalAll(file, io, &buf, 0);

    const abs_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, temp_filename });
    defer allocator.free(abs_path);

    const check_file = try std.Io.Dir.openFile(temp_dir, io, temp_filename, .{ .mode = .read_only });
    defer std.Io.File.close(check_file, io);

    var info = VideoInfo{
        .format = "mp4",
        .width = 0,
        .height = 0,
    };

    try std.testing.expectError(error.InvalidMp4, findTkhdAndMvhdInFile(allocator, check_file, io, 0, 12, &info, 0));
}
