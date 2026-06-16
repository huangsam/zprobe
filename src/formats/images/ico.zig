const std = @import("std");

pub const icoMagic: [4]u8 = .{ 0x00, 0x00, 0x01, 0x00 };

pub fn parseIco(header: []const u8) !struct { width: u32, height: u32 } {
    if (header.len < 22) {
        return error.NotIco;
    }
    if (!std.mem.eql(u8, header[0..4], &icoMagic)) {
        return error.NotIco;
    }

    const w = header[6];
    const h = header[7];

    const width: u32 = if (w == 0) 256 else w;
    const height: u32 = if (h == 0) 256 else h;

    return .{ .width = width, .height = height };
}

test "parse ICO header" {
    // 22-byte mock ICO header.
    // Bytes 0-3: 00 00 01 00 (magic)
    // Bytes 4-5: 01 00 (1 image)
    // Byte 6: width (32)
    // Byte 7: height (32)
    // Bytes 8-21: dummy data
    var header = [_]u8{0} ** 22;
    header[0] = 0x00;
    header[1] = 0x00;
    header[2] = 0x01;
    header[3] = 0x00;
    header[4] = 0x01;
    header[5] = 0x00;
    header[6] = 32;
    header[7] = 32;

    const dims = try parseIco(&header);
    try std.testing.expectEqual(@as(u32, 32), dims.width);
    try std.testing.expectEqual(@as(u32, 32), dims.height);
}

test "parse ICO header: 256px check" {
    var header = [_]u8{0} ** 22;
    header[0] = 0x00;
    header[1] = 0x00;
    header[2] = 0x01;
    header[3] = 0x00;
    header[4] = 0x01;
    header[5] = 0x00;
    header[6] = 0; // 256
    header[7] = 0; // 256

    const dims = try parseIco(&header);
    try std.testing.expectEqual(@as(u32, 256), dims.width);
    try std.testing.expectEqual(@as(u32, 256), dims.height);
}

test "parse ICO header: invalid magic" {
    var header = [_]u8{0} ** 22;
    header[0] = 0x00;
    header[1] = 0x00;
    header[2] = 0x02; // Wrong type
    header[3] = 0x00;

    try std.testing.expectError(error.NotIco, parseIco(&header));
}

test "parse ICO header: too short" {
    var header = [_]u8{0} ** 10;
    try std.testing.expectError(error.NotIco, parseIco(&header));
}
