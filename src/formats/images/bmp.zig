const std = @import("std");

/// Magic bytes signature identifying a BMP file header ("BM").
pub const bmpMagic: [2]u8 = .{ 'B', 'M' };

/// Parse a BMP header from a byte slice to extract image width and height.
/// Returns error.NotBmp if the header length is insufficient or magic bytes do not match.
pub fn parseBmp(header: []const u8) !struct { width: u32, height: u32 } {
    if (header.len < 26 or header[0] != bmpMagic[0] or header[1] != bmpMagic[1])
        return error.NotBmp;

    const w = @as(u32, header[18]) |
        @as(u32, header[19]) << 8 |
        @as(u32, header[20]) << 16 |
        @as(u32, header[21]) << 24;

    const h_u32 = @as(u32, header[22]) |
        @as(u32, header[23]) << 8 |
        @as(u32, header[24]) << 16 |
        @as(u32, header[25]) << 24;

    const h_raw = @as(i32, @bitCast(h_u32));
    const h = @abs(h_raw);

    return .{ .width = w, .height = h };
}

test "parseBmp: top-down bitmap (negative height)" {
    var header = [_]u8{0} ** 26;
    header[0] = 'B';
    header[1] = 'M';
    // width = 320 (0x00000140)
    header[18] = 0x40;
    header[19] = 0x01;
    // height = -240 (0xffffff10)
    header[22] = 0x10;
    header[23] = 0xff;
    header[24] = 0xff;
    header[25] = 0xff;

    const dims = try parseBmp(&header);
    try std.testing.expectEqual(@as(u32, 320), dims.width);
    try std.testing.expectEqual(@as(u32, 240), dims.height);
}

test "parseBmp: zero and large dimensions" {
    var header = [_]u8{0} ** 26;
    header[0] = 'B';
    header[1] = 'M';
    // width = 0, height = 0
    const dims = try parseBmp(&header);
    try std.testing.expectEqual(@as(u32, 0), dims.width);
    try std.testing.expectEqual(@as(u32, 0), dims.height);

    // width = 0xffffffff, height = 0x7fffffff
    header[18] = 0xff;
    header[19] = 0xff;
    header[20] = 0xff;
    header[21] = 0xff;
    header[22] = 0xff;
    header[23] = 0xff;
    header[24] = 0xff;
    header[25] = 0x7f;

    const dims_large = try parseBmp(&header);
    try std.testing.expectEqual(@as(u32, 0xffffffff), dims_large.width);
    try std.testing.expectEqual(@as(u32, 0x7fffffff), dims_large.height);
}
