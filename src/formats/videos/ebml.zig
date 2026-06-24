const std = @import("std");

/// State tracking for parsing EBML (Matroska/WebM) containers.
pub const EbmlState = struct {
    /// Track width of the selected video track, in pixels.
    width: u32 = 0,
    /// Track height of the selected video track, in pixels.
    height: u32 = 0,
    /// Timecode scale factor in nanoseconds, default 1,000,000 (1ms).
    timecode_scale: u64 = 1_000_000,
    /// Unscaled floating-point duration value.
    duration_raw: ?f64 = null,
    /// Type ID of the currently parsed track entry (1 for video, 2 for audio, etc).
    current_track_type: ?u64 = null,
    /// Width of the currently parsed track.
    current_track_width: u32 = 0,
    /// Height of the currently parsed track.
    current_track_height: u32 = 0,
};

/// Get the size in bytes of an EBML Variable-Size Integer (VINT) based on
/// the position of the first set bit (leading zeroes) in its first byte.
pub fn getVintSize(first_byte: u8) !usize {
    if (first_byte == 0) return error.InvalidVint;
    // In EBML, VINT size is determined by the number of leading zero bits plus one.
    // e.g., 1xxxxxxx (0 leading zeros) -> size 1, 01xxxxxx (1 leading zero) -> size 2.
    // `@clz` is a Zig built-in that counts the leading zero bits of the byte.
    return @clz(first_byte) + 1;
}

/// Decode the value of a VINT, clearing the leading marker bit.
/// VINT encoding in EBML uses the first set bit to indicate total length:
/// 1xxxxxxx = 1 byte, 01xxxxxx = 2 bytes, 001xxxxx = 3 bytes, etc.
/// This function masks out the leading marker bits and reassembles the actual value.
pub fn decodeVintVal(buf: []const u8) u64 {
    if (buf.len == 0) return 0;
    // Mask selects only the data bits after the length indicator.
    // Example: for 2-byte VINT (01xxxxxx), mask is 0x3f to keep only xxxxxx.
    const mask: u8 = switch (buf.len) {
        1 => 0x7f, // 1xxxxxxx -> keep 7 bits
        2 => 0x3f, // 01xxxxxx -> keep 6 bits
        3 => 0x1f, // 001xxxxx -> keep 5 bits
        4 => 0x0f, // 0001xxxx -> keep 4 bits
        5 => 0x07, // 00001xxx -> keep 3 bits
        6 => 0x03, // 000001xx -> keep 2 bits
        7 => 0x01, // 0000001x -> keep 1 bit
        8 => 0x00, // 00000001 -> keep 0 bits, all data in remaining bytes
        else => 0,
    };
    // Accumulate value by shifting and combining bytes: (byte1 << 8) | byte2, etc.
    var val = @as(u64, buf[0] & mask);
    for (buf[1..]) |b| {
        val = (val << 8) | b;
    }
    return val;
}

/// Check if a VINT represents an "unknown/undefined" size (all data bits set to 1).
pub fn isVintUnknown(buf: []const u8) bool {
    if (buf.len == 0) return false;
    const mask: u8 = switch (buf.len) {
        1 => 0x7f,
        2 => 0x3f,
        3 => 0x1f,
        4 => 0x0f,
        5 => 0x07,
        6 => 0x03,
        7 => 0x01,
        8 => 0x00,
        else => 0,
    };
    if ((buf[0] & mask) != mask) return false;
    for (buf[1..]) |b| {
        if (b != 0xff) return false;
    }
    return true;
}

/// Read a big-endian unsigned integer of a specific byte size (1-8 bytes)
/// from the file at the given offset.
pub fn readUint(file: anytype, io: anytype, offset: u64, size: u64) !u64 {
    if (size == 0 or size > 8) return 0;
    var buf: [8]u8 = undefined;
    const read = try std.Io.File.readPositionalAll(file, io, buf[0..size], offset);
    if (read < size) return error.InvalidEbml;
    var val: u64 = 0;
    for (buf[0..size]) |b| {
        val = (val << 8) | b;
    }
    return val;
}

/// Read a big-endian float of a specific byte size (4 or 8 bytes)
/// from the file at the given offset.
pub fn readFloat(file: anytype, io: anytype, offset: u64, size: u64) !f64 {
    if (size == 4) {
        var buf: [4]u8 = undefined;
        const read = try std.Io.File.readPositionalAll(file, io, &buf, offset);
        if (read < 4) return error.InvalidEbml;
        const u = std.mem.readInt(u32, &buf, .big);
        const f: f32 = @bitCast(u);
        return @as(f64, @floatCast(f));
    } else if (size == 8) {
        var buf: [8]u8 = undefined;
        const read = try std.Io.File.readPositionalAll(file, io, &buf, offset);
        if (read < 8) return error.InvalidEbml;
        const u = std.mem.readInt(u64, &buf, .big);
        return @bitCast(u);
    }
    return error.InvalidFloatSize;
}

/// Recursively scan EBML elements in the specified offset range, updating the EbmlState
/// when encountering segments, track metadata, dimensions, or time information.
pub fn parseEbmlElements(file: anytype, io: anytype, start_offset: u64, end_offset: u64, state: *EbmlState, depth: usize) !void {
    if (depth > 16) return error.EbmlTooDeep;
    var offset = start_offset;
    while (offset < end_offset) {
        var first_id_byte: [1]u8 = undefined;
        const read_bytes = std.Io.File.readPositionalAll(file, io, &first_id_byte, offset) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (read_bytes == 0) break;

        const id_size = try getVintSize(first_id_byte[0]);
        if (id_size > 4) return error.InvalidEbmlId;
        if (id_size > end_offset - offset) return error.InvalidEbml;

        var id_buf: [4]u8 = undefined;
        const id_read = try std.Io.File.readPositionalAll(file, io, id_buf[0..id_size], offset);
        if (id_read < id_size) return error.InvalidEbml;

        var id: u32 = 0;
        for (id_buf[0..id_size]) |b| {
            id = (id << 8) | b;
        }

        offset += id_size;

        var first_size_byte: [1]u8 = undefined;
        const fs_read = try std.Io.File.readPositionalAll(file, io, &first_size_byte, offset);
        if (fs_read < 1) return error.InvalidEbml;
        const size_len = try getVintSize(first_size_byte[0]);
        if (size_len > end_offset - offset) return error.InvalidEbml;

        var size_buf: [8]u8 = undefined;
        const sz_read = try std.Io.File.readPositionalAll(file, io, size_buf[0..size_len], offset);
        if (sz_read < size_len) return error.InvalidEbml;

        const elem_size = decodeVintVal(size_buf[0..size_len]);
        const is_unknown = isVintUnknown(size_buf[0..size_len]);

        offset += size_len;

        var actual_elem_size = elem_size;
        if (is_unknown) {
            actual_elem_size = end_offset - offset;
        }

        if (actual_elem_size > end_offset - offset) return error.InvalidEbml;

        switch (id) {
            0x18538067, // Segment
            0x1654AE6B, // Tracks
            0xAE, // TrackEntry
            0xE0, // Video
            0x1549A966, // Info
            => {
                if (id == 0xAE) {
                    state.current_track_type = null;
                    state.current_track_width = 0;
                    state.current_track_height = 0;
                }

                try parseEbmlElements(file, io, offset, offset + actual_elem_size, state, depth + 1);

                if (id == 0xAE) {
                    if (state.current_track_type == 1) {
                        if (state.current_track_width > 0 and state.current_track_height > 0) {
                            if (state.width == 0) {
                                state.width = state.current_track_width;
                                state.height = state.current_track_height;
                            }
                        }
                    }
                }
            },
            0x83 => { // TrackType
                state.current_track_type = try readUint(file, io, offset, actual_elem_size);
            },
            0xB0 => { // PixelWidth
                state.current_track_width = @intCast(try readUint(file, io, offset, actual_elem_size));
            },
            0xBA => { // PixelHeight
                state.current_track_height = @intCast(try readUint(file, io, offset, actual_elem_size));
            },
            0x2AD7B1 => { // TimecodeScale
                state.timecode_scale = try readUint(file, io, offset, actual_elem_size);
            },
            0x4489 => { // Duration
                state.duration_raw = try readFloat(file, io, offset, actual_elem_size);
            },
            else => {},
        }

        offset += actual_elem_size;
    }
}

test "EBML helper functions" {
    try std.testing.expectEqual(@as(usize, 1), try getVintSize(0x80));
    try std.testing.expectEqual(@as(usize, 2), try getVintSize(0x40));
    try std.testing.expectEqual(@as(usize, 8), try getVintSize(0x01));
    try std.testing.expectError(error.InvalidVint, getVintSize(0x00));

    try std.testing.expectEqual(@as(u64, 5), decodeVintVal(&[_]u8{0x85}));
    try std.testing.expectEqual(@as(u64, 0x3fff), decodeVintVal(&[_]u8{ 0x7f, 0xff }));

    try std.testing.expect(isVintUnknown(&[_]u8{0xff}));
    try std.testing.expect(isVintUnknown(&[_]u8{ 0x7f, 0xff }));
    try std.testing.expect(!isVintUnknown(&[_]u8{ 0x7f, 0xfe }));
}

test "parseEbmlElements keeps first video track's dimensions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_utils = @import("../../core/test_utils.zig");

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;
    const temp_filename = "temp_test_ebml_multitrack.webm";

    const file = try std.Io.Dir.createFile(temp_dir, io, temp_filename, .{});
    defer std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(temp_dir, io, temp_filename) catch {};

    // Build a mock EBML layout with two Tracks -> TrackEntry boxes.
    // Segment ID (0x18538067)
    //   Tracks ID (0x1654AE6B)
    //     TrackEntry ID (0xAE) -> Type = 1, Width = 1920, Height = 1080
    //     TrackEntry ID (0xAE) -> Type = 1, Width = 640, Height = 480
    var buf = [_]u8{0} ** 40;

    // Segment ID (0x18538067)
    buf[0] = 0x18;
    buf[1] = 0x53;
    buf[2] = 0x80;
    buf[3] = 0x67;
    // Segment Size (35 -> 0xA3)
    buf[4] = 0xA3;

    // Tracks ID (0x1654AE6B)
    buf[5] = 0x16;
    buf[6] = 0x54;
    buf[7] = 0xAE;
    buf[8] = 0x6B;
    // Tracks Size (30 -> 0x9E)
    buf[9] = 0x9E;

    // TrackEntry 1 (offset 10, size 13 -> 0x8D)
    buf[10] = 0xAE;
    buf[11] = 0x8D;
    // TrackType ID (0x83), size 1 (0x81), type 1 (0x01)
    buf[12] = 0x83;
    buf[13] = 0x81;
    buf[14] = 0x01;
    // Video ID (0xE0), size 8 (0x88)
    buf[15] = 0xE0;
    buf[16] = 0x88;
    // PixelWidth ID (0xB0), size 2 (0x82), width 1920 (0x0780)
    buf[17] = 0xB0;
    buf[18] = 0x82;
    buf[19] = 0x07;
    buf[20] = 0x80;
    // PixelHeight ID (0xBA), size 2 (0x82), height 1080 (0x0438)
    buf[21] = 0xBA;
    buf[22] = 0x82;
    buf[23] = 0x04;
    buf[24] = 0x38;

    // TrackEntry 2 (offset 25, size 13 -> 0x8D)
    const t2_off = 25;
    buf[t2_off + 0] = 0xAE;
    buf[t2_off + 1] = 0x8D;
    // TrackType ID (0x83), size 1 (0x81), type 1 (0x01)
    buf[t2_off + 2] = 0x83;
    buf[t2_off + 3] = 0x81;
    buf[t2_off + 4] = 0x01;
    // Video ID (0xE0), size 8 (0x88)
    buf[t2_off + 5] = 0xE0;
    buf[t2_off + 6] = 0x88;
    // PixelWidth ID (0xB0), size 2 (0x82), width 640 (0x0280)
    buf[t2_off + 7] = 0xB0;
    buf[t2_off + 8] = 0x82;
    buf[t2_off + 9] = 0x02;
    buf[t2_off + 10] = 0x80;
    // PixelHeight ID (0xBA), size 2 (0x82), height 480 (0x01E0)
    buf[t2_off + 11] = 0xBA;
    buf[t2_off + 12] = 0x82;
    buf[t2_off + 13] = 0x01;
    buf[t2_off + 14] = 0xE0;

    try std.Io.File.writePositionalAll(file, io, &buf, 0);

    const check_file = try std.Io.Dir.openFile(temp_dir, io, temp_filename, .{ .mode = .read_only });
    defer std.Io.File.close(check_file, io);

    var state = EbmlState{};
    try parseEbmlElements(check_file, io, 0, 40, &state, 0);

    // Track 1 dimensions should win (1920x1080), not overridden by Track 2 (640x480).
    try std.testing.expectEqual(@as(u32, 1920), state.width);
    try std.testing.expectEqual(@as(u32, 1080), state.height);
}
