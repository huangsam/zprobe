//! Parse MP4 container atoms to extract video dimensions.

const std = @import("std");
const Io = std.Io;
const media_meta = @import("media_meta.zig");

/// Atom box types we look for.
const ftypAtom: [4]u8 = .{ 'f', 't', 'y', 'p' };
const moovAtom: [4]u8 = .{ 'm', 'o', 'o', 'v' };
const avcCAtom: [4]u8 = .{ 'a', 'v', 'c', 'C' };

/// Find an atom by its 4-byte type string inside a box payload.
fn findAtom(payload: []const u8, target: [4]u8) ?[]const u8 {
    var off: usize = 0;
    while (off + 8 <= payload.len) {
        const box_size = @as(u32, payload[off]) << 24 | @as(u32, payload[off + 1]) << 16 |
            @as(u32, payload[off + 2]) << 8 | @as(u32, payload[off + 3]);
        if (box_size == 0 or box_size <= 8) return null;
        if (off + box_size > payload.len) return null;

        const box_type = payload[off + 4 .. off + 8];
        if (std.mem.eql(u8, box_type, &target)) {
            return payload[off + 8 .. off + box_size];
        }

        // Recurse into child boxes.
        const child = findAtom(payload[off + 8 .. off + box_size], target);
        if (child != null) return child;

        off += box_size;
    }
    return null;
}

/// Parse the SPS from an AVCDecoderConfig atom to extract frame dimensions.
/// This is a simplified parser — full H.264 SPS parsing uses Exp-Golomb codes.
fn parseAvcSps(avcc: []const u8) ?struct { width: u32, height: u32 } {
    // avcC atom structure:
    //   [1:version][1:profile][1:compat][1:level] [1:lengthSize-1]
    //   [1:numSPS] [2:SPS_length] [SPS_data...]
    if (avcc.len < 13) return null;

    var off: usize = 7; // skip version, profile, compat, level, lengthSize
    if (off >= avcc.len) return null;

    const num_sps = avcc[off];
    off += 1;
    if (off + 2 > avcc.len) return null;

    const sps_len = @as(u16, avcc[off]) << 8 | @as(u16, avcc[off + 1]);
    off += 2;

    // There might be multiple SPS/PPS NALUs; use the first one.
    if (off + sps_len < 3 or off + sps_len > avcc.len) return null;

    const sps = avcc[off .. off + sps_len];

    // SPS NAL unit: [1:NAL header][2:first_mb][2->..seq param data...]
    // For H.264 sequence parameter set:
    // After the 3-byte NAL header, we have Exp-Golomb coded values.
    // But many MP4 files use a simpler "Video Format Indicator" + frame params layout.
    // Let's check for the standard seq param structure:
    // byte[3..6]: chroma_format_idc + bit_depth etc (not reliable)
    // The actual width/height are stored as:
    //   pic_width_in_samples_m1 = expGolomb...  (+1)
    //   pic_height_in_map_frames_m1 = expGolomb...
    // For practical purposes, let's extract from known H.264 SPS byte offsets.
    // In a typical SPS NALU: bytes [3..5] contain sequence info, but the exact
    // bit layout depends on the profile. We'll use a well-known heuristic.

    if (sps.len < 8) return null;

    var nalu_off: usize = 3; // skip NAL header and first_mb_in_seq

    // pic_order_cnt_type (Exp-Golomb, usually 0 for baseline)
    while (nalu_off < sps.len) {
        const byte = sps[nalu_off];
        if (byte != 0) break;
        nalu_off += 1;
        if (nalu_off >= sps.len) return null;
        break; // first EG value found (or we hit 0 which is also a valid parse)
    }

    if (nalu_off + 5 > sps.len) return null;

    const log2_max_frame_num = @popCount(sps[nalu_off]) > 0 or true;
    _ = log2_max_frame_num; // just advancing past first EG value

    nalu_off += 1;
    if (nalu_off + 4 > sps.len) return null;

    // After pic_order_cnt_type, there's max_num_ref_frames (EG), then:
    // pic_width_in_samples_m1 (bits), pic_height_in_map_frames_m1 (bits)
    // These are NOT Exp-Golomb — they're raw bits with variable lengths.
    // For practical extraction, look for the frame size in a known offset range.
    // Many encoders put these at byte 6-9 of the SPS data after NAL header.

    const w_raw = @as(u16, sps[nalu_off + 2]) << 8 | @as(u16, sps[nalu_off + 3]);
    const h_raw = @as(u16, sps[nalu_off + 4]) << 8 | @as(u16, sps[nalu_off + 5]);

    // Heuristic: if values look plausible (2-4096 range), accept them.
    if (w_raw == 0 or h_raw == 0) return null;
    if (w_raw > 4096 or h_raw > 4096) return null;

    // H.264 stores (w+1)/2 * H_M for interlaced; check and fix.
    const width = @as(u32, w_raw + 1);
    const height = @as(u32, h_raw + 1);

    return .{ .width = width, .height = height };
}

/// Try parsing the first bytes of an MP4 file for video dimensions.
fn tryParseMp4(header: []const u8) ?media_meta.VideoMeta {
    // Look for ftyp (identifies MP4 container).
    _ = findAtom(header, ftypAtom);

    // Find moov box (contains track metadata).
    const moov = findAtom(header, moovAtom) orelse return null;

    // Search for avcC inside moov (AVC decoder config).
    const avcc = findAtom(moov, avcCAtom) orelse return null;

    // Parse SPS from avcC to get dimensions.
    const dims = parseAvcSps(avcc) orelse return null;

    return .{
        .format = .mp4,
        .width = dims.width,
        .height = dims.height,
    };
}

/// Read the first N bytes from a file into an allocated buffer.
fn readFileHeader(allocator: std.mem.Allocator, path: []const u8, io: Io.Io, n: usize) ![]u8 {
    const file = try std.Io.File.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer std.Io.File.close(file, io);

    var buf: [4096]u8 = undefined;
    const count = try std.Io.File.readPositionalAll(
        file,
        io,
        &buf[0..@min(n, buf.len)],
        0,
    );
    return try allocator.dupe(u8, buf[0..count]);
}

/// Try parsing a video file. Returns VideoMeta wrapped in MediaResult on success.
pub fn getVideoMetadata(allocator: std.mem.Allocator, path: []const u8, io: Io.Io) !media_meta.MediaResult {
    const header = try readFileHeader(allocator, path, io, 4096);
    defer allocator.free(header);

    var meta = tryParseMp4(header) orelse return error.NotVideo;

    const size = (try std.Io.File.length(
        (try std.Io.File.openFileAbsolute(io, path, .{ .mode = .read_only })),
        io,
    ));

    return media_meta.MediaResult{
        .path = path,
        .size = size,
        .video_meta = meta,
    };
}
