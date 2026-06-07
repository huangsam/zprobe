const std = @import("std");
const Dir = std.Io.Dir;
const media_meta = @import("media_meta.zig");

const Dims = struct {
    width: u32,
    height: u32,
};

fn parseTkhd(payload: []const u8) ?Dims {
    if (payload.len < 80) return null;

    const version = payload[0];
    var w_off: usize = 0;
    var h_off: usize = 0;

    if (version == 0) {
        // Version 0 tkhd size is 84 bytes (payload size 76)
        // Width starts at offset 76 in the payload (meaning index 76..80)
        // Height starts at offset 80 in the payload (meaning index 80..84)
        if (payload.len < 84) return null;
        w_off = 76;
        h_off = 80;
    } else if (version == 1) {
        // Version 1 tkhd size is 96 bytes (payload size 88)
        // Width starts at offset 88 in the payload (meaning index 88..92)
        // Height starts at offset 92 in the payload (meaning index 92..96)
        if (payload.len < 96) return null;
        w_off = 88;
        h_off = 92;
    } else {
        return null;
    }

    // Width and height are 16.16 fixed point big-endian.
    // Integer part is the first 2 bytes.
    const w = @as(u32, payload[w_off]) << 8 | @as(u32, payload[w_off + 1]);
    const h = @as(u32, payload[h_off]) << 8 | @as(u32, payload[h_off + 1]);

    return .{ .width = w, .height = h };
}

fn findTkhdInPayload(payload: []const u8) ?Dims {
    var off: usize = 0;
    while (off + 8 <= payload.len) {
        const box_size = @as(u32, payload[off]) << 24 |
            @as(u32, payload[off + 1]) << 16 |
            @as(u32, payload[off + 2]) << 8 |
            @as(u32, payload[off + 3]);
        if (box_size < 8 or off + box_size > payload.len) return null;

        const box_type = payload[off + 4 .. off + 8];
        if (std.mem.eql(u8, box_type, "tkhd")) {
            const tkhd_payload = payload[off + 8 .. off + box_size];
            if (parseTkhd(tkhd_payload)) |dims| {
                if (dims.width > 0 and dims.height > 0) {
                    return dims;
                }
            }
        }

        // Recurse into child container boxes to find tkhd.
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

/// Try parsing a video file. Returns VideoMeta wrapped in MediaResult on success.
pub fn getVideoMetadata(allocator: std.mem.Allocator, path: []const u8, io: anytype) !media_meta.MediaResult {
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

        // If size is 0, it means it extends to the end of the file
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
                return media_meta.MediaResult{
                    .path = path,
                    .size = size,
                    .video_meta = .{
                        .format = .mp4,
                        .width = dims.width,
                        .height = dims.height,
                    },
                };
            }
            return error.NoVideoTrack;
        }

        offset += real_size;
    }

    return error.NotVideo;
}

test "parse MP4 moov/trak/tkhd version 0 payload" {
    var buf = [_]u8{0} ** 100;

    // trak box header at offset 0: size 92, type "trak"
    buf[0] = 0; buf[1] = 0; buf[2] = 0; buf[3] = 92;
    buf[4] = 't'; buf[5] = 'r'; buf[6] = 'a'; buf[7] = 'k';

    // tkhd box header at offset 8: size 84, type "tkhd"
    buf[8] = 0; buf[9] = 0; buf[10] = 0; buf[11] = 84;
    buf[12] = 't'; buf[13] = 'k'; buf[14] = 'h'; buf[15] = 'd';

    // tkhd payload starts at offset 16
    // version = 0 (offset 16)
    buf[16] = 0;

    // width: 640 (offset 16 + 76 = 92) -> big-endian 16.16 = 02 80 00 00
    buf[92] = 0x02; buf[93] = 0x80;

    // height: 480 (offset 16 + 80 = 96) -> big-endian 16.16 = 01 e0 00 00
    buf[96] = 0x01; buf[97] = 0xe0;

    const dims = findTkhdInPayload(&buf) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 640), dims.width);
    try std.testing.expectEqual(@as(u32, 480), dims.height);
}
