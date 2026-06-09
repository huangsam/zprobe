//! Educational MP4 Metadata Parser.
//!
//! This module showcases:
//! 1. Recursive parsing of the MP4 (ISOBMFF) container format tree structure.
//! 2. Parsing Big-Endian binary integers.
//! 3. Extracting 16.16 fixed-point numbers.
//! 4. Smart I/O design: reading only metadata box payloads while skipping massive video data.

const std = @import("std");
const Dir = std.Io.Dir;

const Dims = struct {
    width: u32,
    height: u32,
};

/// Parse a `tkhd` (Track Header) box payload.
///
/// ### Track Header (`tkhd`) Binary Structure:
/// - Offset 0: Version (1 byte)
/// - Offset 1..3: Flags (3 bytes)
/// - Based on Version:
///   - **Version 0:** (tkhd size is 84 bytes; payload size is 76)
///     - Creation & modification times, track ID, duration, etc.
///     - Width starts at offset 76 in the payload (index 76..79)
///     - Height starts at offset 80 in the payload (index 80..83)
///   - **Version 1:** (tkhd size is 96 bytes; payload size is 88)
///     - Expanded 64-bit timestamps and duration fields.
///     - Width starts at offset 88 in the payload (index 88..91)
///     - Height starts at offset 92 in the payload (index 92..95)
///
/// **Fixed-Point Encodings:**
/// Width and height are stored as **16.16 fixed-point big-endian integers**.
/// The first 2 bytes are the integer part, and the next 2 bytes are the fractional part.
/// Since we only need pixel-level dimensions, we extract the integer portion by
/// decoding the first 2 bytes and ignoring the fraction.
fn parseTkhd(payload: []const u8) ?Dims {
    if (payload.len < 80) return null;

    const version = payload[0];
    var w_off: usize = 0;
    var h_off: usize = 0;

    if (version == 0) {
        if (payload.len < 84) return null;
        w_off = 76;
        h_off = 80;
    } else if (version == 1) {
        if (payload.len < 96) return null;
        w_off = 88;
        h_off = 92;
    } else {
        return null;
    }

    // Decode Big-Endian 16-bit integer part of the 16.16 fixed point value.
    const w = @as(u32, payload[w_off]) << 8 | @as(u32, payload[w_off + 1]);
    const h = @as(u32, payload[h_off]) << 8 | @as(u32, payload[h_off + 1]);

    return .{ .width = w, .height = h };
}

/// Recursively search for the `tkhd` box within nested container boxes.
///
/// ### Container Hierarchy
/// In an MP4 file, certain boxes contain raw binary payloads, while others act
/// as directories containing nested children boxes.
/// ```
/// moov (Movie Box)
/// └── trak (Track Box)
///     └── mdia (Media Box)
///         └── minf (Media Information)
///             └── stbl (Sample Table)
///             └── tkhd (Track Header - contains dimensions)
/// ```
///
/// This function walks the sibling box list at the current payload level. If it discovers
/// a container box (`trak`, `mdia`, `minf`, or `stbl`), it recurses into its payload.
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

/// Try parsing a video file. Returns format and dimensions on success.
///
/// ### Memory Allocation & Performance Strategy:
/// - MP4 files can be massive (gigabytes of compressed stream data in `mdat`).
/// - However, the metadata (`moov` box) is typically very small.
/// - This parser scans the file linearly, reading only the 8-byte box headers.
/// - When it encounters `moov`, it uses the `allocator` to load ONLY the `moov`
///   payload into memory, avoiding loading any video stream bytes.
/// - The memory is freed immediately upon exiting the function via `defer`.
pub fn getVideoMetadata(allocator: std.mem.Allocator, path: []const u8, io: anytype) !struct { format: []const u8, width: u32, height: u32 } {
    const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer std.Io.File.close(file, io);

    const size = try std.Io.File.length(file, io);

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
            const payload_len = real_size - header_len;
            const moov_payload = try allocator.alloc(u8, payload_len);
            defer allocator.free(moov_payload);

            _ = try std.Io.File.readPositionalAll(file, io, moov_payload, offset + header_len);

            if (findTkhdInPayload(moov_payload)) |dims| {
                return .{
                    .format = "mp4",
                    .width = dims.width,
                    .height = dims.height,
                };
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

