const std = @import("std");

pub const bmpMagic: [2]u8 = .{ 'B', 'M' };

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
    const h = if (h_raw < 0) @as(u32, @intCast(-h_raw)) else h_u32;

    return .{ .width = w, .height = h };
}
