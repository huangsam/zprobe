const std = @import("std");

/// Magic bytes signature identifying a GIF file header ("GIF8").
pub const gifMagic: [4]u8 = .{ 'G', 'I', 'F', '8' };

/// Parse a GIF header from a byte slice to extract logical screen width and height.
/// Returns error.NotGif if header length is insufficient or magic bytes do not match.
pub fn parseGif(header: []const u8) !struct { width: u16, height: u16 } {
    if (header.len < 10 or !std.mem.eql(u8, header[0..4], &gifMagic))
        return error.NotGif;

    const w = @as(u16, header[6]) | (@as(u16, header[7]) << 8);
    const h = @as(u16, header[8]) | (@as(u16, header[9]) << 8);

    return .{ .width = w, .height = h };
}

test "parseGif: boundary and zero checks" {
    var header = [_]u8{0} ** 10;
    @memcpy(header[0..4], &gifMagic);

    // width = 0, height = 0
    const dims = try parseGif(&header);
    try std.testing.expectEqual(@as(u16, 0), dims.width);
    try std.testing.expectEqual(@as(u16, 0), dims.height);

    // width = 65535, height = 65535
    header[6] = 0xff;
    header[7] = 0xff;
    header[8] = 0xff;
    header[9] = 0xff;

    const dims_large = try parseGif(&header);
    try std.testing.expectEqual(@as(u16, 65535), dims_large.width);
    try std.testing.expectEqual(@as(u16, 65535), dims_large.height);
}
