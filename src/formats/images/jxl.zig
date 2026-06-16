const std = @import("std");

pub const jxlBareMagic: [2]u8 = .{ 0xFF, 0x0A };
pub const jxlBoxMagic: [12]u8 = .{ 0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A };

const BitReader = struct {
    bytes: []const u8,
    bit_offset: usize = 0,

    fn readBits(self: *BitReader, comptime num_bits: usize) !u32 {
        if (self.bit_offset + num_bits > self.bytes.len * 8) return error.OutOfBounds;
        var value: u32 = 0;
        var i: usize = 0;
        while (i < num_bits) : (i += 1) {
            const byte_idx = self.bit_offset / 8;
            const bit_idx = self.bit_offset % 8;
            const bit = (self.bytes[byte_idx] >> @intCast(bit_idx)) & 1;
            value |= @as(u32, bit) << @intCast(i);
            self.bit_offset += 1;
        }
        return value;
    }
};

fn readJxlU32(br: *BitReader) !u32 {
    const selector = try br.readBits(2);
    switch (selector) {
        0b00 => {
            const val = try br.readBits(8);
            return val + 1;
        },
        0b01 => {
            const val = try br.readBits(10);
            return val + 1;
        },
        0b10 => {
            const val = try br.readBits(14);
            return val + 1;
        },
        0b11 => {
            const val = try br.readBits(30);
            return val + 1;
        },
        else => unreachable,
    }
}

pub const ImageDims = struct { width: u32, height: u32 };

pub fn parseJxlCodestream(bytes: []const u8) !ImageDims {
    if (bytes.len < 2) return error.JxlTooShort;
    var br = BitReader{ .bytes = bytes };

    const m0 = try br.readBits(8);
    const m1 = try br.readBits(8);
    if (m0 != 0xFF or m1 != 0x0A) return error.NotJxl;

    const div8 = try br.readBits(1);
    var height: u32 = 0;
    if (div8 == 1) {
        const h_val = try br.readBits(8);
        height = (h_val + 1) * 8;
    } else {
        height = try readJxlU32(&br);
    }

    const w_div8 = try br.readBits(1);
    var width: u32 = 0;
    if (w_div8 == 1) {
        const w_val = try br.readBits(8);
        width = (w_val + 1) * 8;
    } else {
        width = try readJxlU32(&br);
    }

    return ImageDims{ .width = width, .height = height };
}

fn walkJxlBoxes(file: anytype, io: anytype, start_offset: u64, end_offset: u64) !ImageDims {
    var offset = start_offset;
    while (offset + 8 <= end_offset) {
        var header_buf: [8]u8 = undefined;
        const read_bytes = try std.Io.File.readPositionalAll(file, io, &header_buf, offset);
        if (read_bytes < 8) return error.JxlTooShort;

        const box_size = @as(u64, header_buf[0]) << 24 |
            @as(u64, header_buf[1]) << 16 |
            @as(u64, header_buf[2]) << 8 |
            @as(u64, header_buf[3]);

        const box_type = header_buf[4..8];

        var header_len: u64 = 8;
        var real_size = box_size;

        if (box_size == 1) {
            var ext_size_buf: [8]u8 = undefined;
            const ext_read = try std.Io.File.readPositionalAll(file, io, &ext_size_buf, offset + 8);
            if (ext_read < 8) return error.JxlTooShort;
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

        if (real_size < header_len or offset + real_size > end_offset) return error.InvalidJxl;

        if (std.mem.eql(u8, box_type, "jxlc") or std.mem.eql(u8, box_type, "jxli")) {
            const payload_len = real_size - header_len;
            var codestream_buf: [64]u8 = undefined;
            const read_len = @min(payload_len, codestream_buf.len);
            const cs_read = try std.Io.File.readPositionalAll(file, io, codestream_buf[0..read_len], offset + header_len);
            if (cs_read >= 2) {
                return parseJxlCodestream(codestream_buf[0..cs_read]);
            }
        }

        offset += real_size;
    }
    return error.JxlNoCodestream;
}

pub fn parseJxl(allocator: std.mem.Allocator, file: anytype, io: anytype, header: []const u8, size: u64) !ImageDims {
    _ = allocator;
    if (header.len >= 2 and std.mem.eql(u8, header[0..2], &jxlBareMagic)) {
        return parseJxlCodestream(header);
    } else if (header.len >= 12 and std.mem.eql(u8, header[0..12], &jxlBoxMagic)) {
        return walkJxlBoxes(file, io, 0, size);
    }
    return error.NotJxl;
}

test "parse bare JXL codestream - div8" {
    // FF 0A (magic)
    // 1 (div8 height) | 00000100 (height = (4+1)*8 = 40)
    // 1 (div8 width) | 00000111 (width = (7+1)*8 = 64)
    // We bitpack this:
    // Bits of byte 2:
    // div8 = 1 (bit 0)
    // height_val = 4 (bits 1..8) -> 00000100 -> height_val << 1 = 00001000. Combined with div8: 00001001 (0x09)
    // height_val bit 7 (bit 8 of stream) is 0.
    // Next: div8_w = 1 (bit 9)
    // width_val = 7 (bits 10..17) -> 00000111 -> width_val << 2 = 00011100.
    // So byte 2 (bits 0-7): 0x09
    // Byte 3 (bits 8-15):
    // bit 8: height_val[7] = 0
    // bit 9: div8_w = 1
    // bits 10-15: width_val[0-5] = 000111 -> combined: 00011110 (0x1E)
    // Byte 4 (bits 16-23): width_val[6-7] = 00
    var buf = [_]u8{0} ** 5;
    buf[0] = 0xFF;
    buf[1] = 0x0A;
    buf[2] = 0x09;
    buf[3] = 0x1E;
    buf[4] = 0x00;

    const dims = try parseJxlCodestream(&buf);
    try std.testing.expectEqual(@as(u32, 64), dims.width);
    try std.testing.expectEqual(@as(u32, 40), dims.height);
}

test "parse JXL container walk" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cwd = std.Io.Dir.cwd();
    const temp_filename = "temp_test_jxl.jxl";

    const file = try std.Io.Dir.createFile(cwd, io, temp_filename, .{});
    defer std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(cwd, io, temp_filename) catch {};

    var buf = [_]u8{0} ** 30;
    // JXL box magic
    @memcpy(buf[0..12], &jxlBoxMagic);
    // jxlc box size: 18 (0x00000012)
    buf[12] = 0;
    buf[13] = 0;
    buf[14] = 0;
    buf[15] = 18;
    buf[16] = 'j';
    buf[17] = 'x';
    buf[18] = 'l';
    buf[19] = 'c';
    // Codestream inside jxlc: FF 0A 09 1E 00
    buf[20] = 0xFF;
    buf[21] = 0x0A;
    buf[22] = 0x09;
    buf[23] = 0x1E;
    buf[24] = 0x00;

    try std.Io.File.writePositionalAll(file, io, &buf, 0);

    const abs_path = try cwd.realPathFileAlloc(io, temp_filename, allocator);
    defer allocator.free(abs_path);

    const check_file = try std.Io.Dir.openFileAbsolute(io, abs_path, .{ .mode = .read_only });
    defer std.Io.File.close(check_file, io);

    const res = try parseJxl(allocator, check_file, io, &buf, buf.len);
    try std.testing.expectEqual(@as(u32, 64), res.width);
    try std.testing.expectEqual(@as(u32, 40), res.height);
}
