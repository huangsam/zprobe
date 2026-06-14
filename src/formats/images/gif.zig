const std = @import("std");

pub const gifMagic: [4]u8 = .{ 'G', 'I', 'F', '8' };

pub fn parseGif(header: []const u8) !struct { width: u16, height: u16 } {
    if (header.len < 10 or !std.mem.eql(u8, header[0..4], &gifMagic))
        return error.NotGif;

    const w = @as(u16, header[6]) | (@as(u16, header[7]) << 8);
    const h = @as(u16, header[8]) | (@as(u16, header[9]) << 8);

    return .{ .width = w, .height = h };
}
