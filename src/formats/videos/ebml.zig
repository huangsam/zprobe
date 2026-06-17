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
    if (first_byte & 0x80 != 0) return 1;
    if (first_byte & 0x40 != 0) return 2;
    if (first_byte & 0x20 != 0) return 3;
    if (first_byte & 0x10 != 0) return 4;
    if (first_byte & 0x08 != 0) return 5;
    if (first_byte & 0x04 != 0) return 6;
    if (first_byte & 0x02 != 0) return 7;
    if (first_byte & 0x01 != 0) return 8;
    return error.InvalidVint;
}

/// Decode the value of a VINT, clearing the leading marker bit.
pub fn decodeVintVal(buf: []const u8) u64 {
    if (buf.len == 0) return 0;
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
    _ = try std.Io.File.readPositionalAll(file, io, buf[0..size], offset);
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
        _ = try std.Io.File.readPositionalAll(file, io, &buf, offset);
        const u = std.mem.readInt(u32, &buf, .big);
        const f: f32 = @bitCast(u);
        return @as(f64, @floatCast(f));
    } else if (size == 8) {
        var buf: [8]u8 = undefined;
        _ = try std.Io.File.readPositionalAll(file, io, &buf, offset);
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
        if (id_size > end_offset - offset) break;

        var id_buf: [4]u8 = undefined;
        _ = try std.Io.File.readPositionalAll(file, io, id_buf[0..id_size], offset);

        var id: u32 = 0;
        for (id_buf[0..id_size]) |b| {
            id = (id << 8) | b;
        }

        offset += id_size;

        var first_size_byte: [1]u8 = undefined;
        _ = try std.Io.File.readPositionalAll(file, io, &first_size_byte, offset);
        const size_len = try getVintSize(first_size_byte[0]);
        if (size_len > end_offset - offset) break;

        var size_buf: [8]u8 = undefined;
        _ = try std.Io.File.readPositionalAll(file, io, size_buf[0..size_len], offset);

        const elem_size = decodeVintVal(size_buf[0..size_len]);
        const is_unknown = isVintUnknown(size_buf[0..size_len]);

        offset += size_len;

        var actual_elem_size = elem_size;
        if (is_unknown) {
            actual_elem_size = end_offset - offset;
        }

        if (actual_elem_size > end_offset - offset) break;

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
                            state.width = state.current_track_width;
                            state.height = state.current_track_height;
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
