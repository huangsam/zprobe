const std = @import("std");
const ByteReader = @import("../../core/byte_reader.zig").ByteReader;
const test_utils = @import("../../core/test_utils.zig");

pub const avifMagic: [4]u8 = .{ 'f', 't', 'y', 'p' };

pub const ImageDims = struct { width: u32, height: u32 };

fn walkBoxes(file: anytype, io: anytype, start_offset: u64, end_offset: u64) !ImageDims {
    var offset = start_offset;
    while (offset + 8 <= end_offset) {
        var header_buf: [8]u8 = undefined;
        const read_bytes = try std.Io.File.readPositionalAll(file, io, &header_buf, offset);
        if (read_bytes < 8) return error.AvifTooShort;

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
            if (ext_read < 8) return error.AvifTooShort;
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
        if (real_size < header_len or real_size > end_offset - offset) return error.InvalidAvif;

        if (std.mem.eql(u8, box_type, "meta")) {
            // meta box is a FullBox, skip 4 bytes of version/flags
            if (real_size >= header_len + 4) {
                if (walkBoxes(file, io, offset + header_len + 4, offset + real_size)) |dims| {
                    return dims;
                } else |_| {}
            }
        } else if (std.mem.eql(u8, box_type, "iprp") or std.mem.eql(u8, box_type, "ipco")) {
            if (walkBoxes(file, io, offset + header_len, offset + real_size)) |dims| {
                return dims;
            } else |_| {}
        } else if (std.mem.eql(u8, box_type, "ispe")) {
            // ispe is a FullBox: 4 bytes version/flags, then width: u32, height: u32
            if (real_size >= header_len + 12) {
                var ispe_buf: [12]u8 = undefined;
                const ispe_read = try std.Io.File.readPositionalAll(file, io, &ispe_buf, offset + header_len);
                if (ispe_read >= 12) {
                    const width = @as(u32, ispe_buf[4]) << 24 |
                        @as(u32, ispe_buf[5]) << 16 |
                        @as(u32, ispe_buf[6]) << 8 |
                        @as(u32, ispe_buf[7]);
                    const height = @as(u32, ispe_buf[8]) << 24 |
                        @as(u32, ispe_buf[9]) << 16 |
                        @as(u32, ispe_buf[10]) << 8 |
                        @as(u32, ispe_buf[11]);
                    if (width > 0 and height > 0) {
                        return ImageDims{ .width = width, .height = height };
                    }
                }
            }
        }

        offset += real_size;
    }
    return error.AvifNoIspe;
}

pub fn parseAvif(allocator: std.mem.Allocator, file: anytype, io: anytype, size: u64) !ImageDims {
    _ = allocator;
    return walkBoxes(file, io, 0, size);
}

test "parse AVIF mock boxes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;
    const temp_filename = "temp_test_avif.avif";

    const file = try std.Io.Dir.createFile(temp_dir, io, temp_filename, .{});
    defer std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(temp_dir, io, temp_filename) catch {};

    // Let's build a mock AVIF with ftyp box, meta box, iprp, ipco, ispe.
    // Box structure:
    // ftyp (size 16)
    // meta (size 64) -> contains iprp (size 48) -> contains ipco (size 36) -> contains ispe (size 20)

    var buf = [_]u8{0} ** 80;

    // ftyp box
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 16;
    buf[4] = 'f';
    buf[5] = 't';
    buf[6] = 'y';
    buf[7] = 'p';
    buf[8] = 'a';
    buf[9] = 'v';
    buf[10] = 'i';
    buf[11] = 'f';
    buf[12] = 0;
    buf[13] = 0;
    buf[14] = 0;
    buf[15] = 0;

    // meta box (FullBox, size 64)
    buf[16] = 0;
    buf[17] = 0;
    buf[18] = 0;
    buf[19] = 64;
    buf[20] = 'm';
    buf[21] = 'e';
    buf[22] = 't';
    buf[23] = 'a';
    // 4 bytes flags/version for FullBox
    buf[24] = 0;
    buf[25] = 0;
    buf[26] = 0;
    buf[27] = 0;

    // iprp box (size 48)
    buf[28] = 0;
    buf[29] = 0;
    buf[30] = 0;
    buf[31] = 48;
    buf[32] = 'i';
    buf[33] = 'p';
    buf[34] = 'r';
    buf[35] = 'p';

    // ipco box (size 40)
    buf[36] = 0;
    buf[37] = 0;
    buf[38] = 0;
    buf[39] = 40;
    buf[40] = 'i';
    buf[41] = 'p';
    buf[42] = 'c';
    buf[43] = 'o';

    // ispe box (FullBox, size 20)
    buf[44] = 0;
    buf[45] = 0;
    buf[46] = 0;
    buf[47] = 20;
    buf[48] = 'i';
    buf[49] = 's';
    buf[50] = 'p';
    buf[51] = 'e';
    // FullBox version/flags (4 bytes)
    buf[52] = 0;
    buf[53] = 0;
    buf[54] = 0;
    buf[55] = 0;
    // width: 800 (0x00000320)
    buf[56] = 0;
    buf[57] = 0;
    buf[58] = 0x03;
    buf[59] = 0x20;
    // height: 600 (0x00000258)
    buf[60] = 0;
    buf[61] = 0;
    buf[62] = 0x02;
    buf[63] = 0x58;

    try std.Io.File.writePositionalAll(file, io, &buf, 0);

    const check_file = try std.Io.Dir.openFile(temp_dir, io, temp_filename, .{ .mode = .read_only });
    defer std.Io.File.close(check_file, io);

    const res = try parseAvif(allocator, check_file, io, buf.len);
    try std.testing.expectEqual(@as(u32, 800), res.width);
    try std.testing.expectEqual(@as(u32, 600), res.height);
}
