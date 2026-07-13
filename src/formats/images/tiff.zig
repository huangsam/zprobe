const std = @import("std");
const ByteReader = @import("../../core/byte_reader.zig").ByteReader;
const utils = @import("../../core/utils.zig");
const common = @import("common.zig");
const ImageMetadata = common.ImageMetadata;

fn getTypeSize(t: u16) usize {
    return switch (t) {
        1, 2, 7 => 1,
        3 => 2,
        4, 9 => 4,
        5, 10 => 8,
        else => 0,
    };
}

/// Parse an Image File Directory (IFD) from a TIFF stream, reading EXIF tags
/// (e.g. dimensions, camera make/model, orientation) and recursing into sub-IFDs
/// (such as EXIF and GPS sub-IFDs) up to a maximum recursion depth of 4.
/// Depth limit prevents stack exhaustion on malformed files with circular IFD chains.
pub fn parseIfd(
    allocator: std.mem.Allocator,
    root_reader: *ByteReader,
    ifd_offset: usize,
    meta: *ImageMetadata,
    depth: usize,
) !void {
    if (depth > 4) return;
    if (ifd_offset == 0 or ifd_offset + 2 > root_reader.buffer.len) return;

    var ifd_reader = ByteReader.init(root_reader.buffer[ifd_offset..], root_reader.endian);
    const num_entries = try ifd_reader.readInt(u16);

    var i: usize = 0;
    while (i < num_entries) : (i += 1) {
        if (ifd_reader.remaining() < 12) break;

        const entry_abs_offset = ifd_offset + 2 + i * 12;

        const tag = try ifd_reader.readInt(u16);
        const type_id = try ifd_reader.readInt(u16);
        const count = try ifd_reader.readInt(u32);
        const inline_or_offset_val = try ifd_reader.readInt(u32);

        const type_size = getTypeSize(type_id);
        if (type_size == 0) continue;
        const total_size = @as(u64, count) * type_size;

        var val_reader: ByteReader = undefined;
        if (total_size <= 4) {
            val_reader = ByteReader.init(root_reader.buffer[entry_abs_offset + 8 .. entry_abs_offset + 12], root_reader.endian);
        } else {
            if (total_size > root_reader.buffer.len or inline_or_offset_val > root_reader.buffer.len - total_size) continue;
            val_reader = ByteReader.init(root_reader.buffer[inline_or_offset_val .. inline_or_offset_val + total_size], root_reader.endian);
        }

        switch (tag) {
            0x0100 => { // ImageWidth (TIFF tag 256)
                if (count == 1) {
                    meta.width = if (type_id == 3) try val_reader.readInt(u16) else try val_reader.readInt(u32);
                }
            },
            0x0101 => { // ImageLength (TIFF tag 257): image height
                if (count == 1) {
                    meta.height = if (type_id == 3) try val_reader.readInt(u16) else try val_reader.readInt(u32);
                }
            },
            0x0112 => { // Orientation (TIFF tag 274): 1=normal, 3=180°, 6=90°CW, 8=270°CW
                if (type_id == 3 and count == 1) {
                    meta.orientation = try val_reader.readInt(u16);
                }
            },
            0x010f => { // Make (TIFF tag 271): camera manufacturer name
                if (type_id == 2) {
                    if (meta.camera_make) |s| allocator.free(s);
                    meta.camera_make = try val_reader.readAscii(allocator, count);
                }
            },
            0x0110 => { // Model (TIFF tag 272): camera model name
                if (type_id == 2) {
                    if (meta.camera_model) |s| allocator.free(s);
                    meta.camera_model = try val_reader.readAscii(allocator, count);
                }
            },
            0x8769 => { // ExifOffset (TIFF tag 34665): pointer to nested EXIF IFD
                if (type_id == 4 and count == 1) {
                    try parseIfd(allocator, root_reader, @as(usize, inline_or_offset_val), meta, depth + 1);
                }
            },
            0x8825 => { // GPSInfo (TIFF tag 34853): pointer to nested GPS IFD
                if (type_id == 4 and count == 1) {
                    try parseGpsIfd(root_reader, @as(usize, inline_or_offset_val), meta);
                }
            },
            0x9003 => { // DateTimeOriginal (EXIF tag 36867): capture timestamp in "YYYY:MM:DD HH:MM:SS" format
                if (type_id == 2) {
                    if (meta.create_time) |s| allocator.free(s);
                    const raw = try val_reader.readAscii(allocator, count);
                    defer allocator.free(raw);
                    meta.create_time = try utils.normalizeDateTime(allocator, raw);
                }
            },
            else => {},
        }
    }

    const needed_bytes = 2 + @as(usize, num_entries) * 12 + 4;
    // Use subtraction-based bounds checking to prevent integer overflow on offset calculation
    if (ifd_offset < root_reader.buffer.len and root_reader.buffer.len - ifd_offset >= needed_bytes) {
        const entry_end_offset = ifd_offset + 2 + @as(usize, num_entries) * 12;
        var offset_reader = ByteReader.init(root_reader.buffer[entry_end_offset .. entry_end_offset + 4], root_reader.endian);
        const next_ifd_offset = try offset_reader.readInt(u32);
        if (depth == 0 and next_ifd_offset != 0) {
            parseIfd1ForThumbnail(allocator, root_reader, @as(usize, next_ifd_offset), meta) catch {};
        }
    }
}

/// Parse a GPS Info IFD from a TIFF stream, extracting latitude/longitude coordinates
/// and ref directions, computing decimal degrees values.
pub fn parseGpsIfd(
    root_reader: *ByteReader,
    ifd_offset: usize,
    meta: *ImageMetadata,
) !void {
    if (ifd_offset == 0 or ifd_offset + 2 > root_reader.buffer.len) return;

    var gps_reader = ByteReader.init(root_reader.buffer[ifd_offset..], root_reader.endian);
    const num_entries = try gps_reader.readInt(u16);

    var lat_ref: ?u8 = null;
    var lat_val: ?f64 = null;
    var lon_ref: ?u8 = null;
    var lon_val: ?f64 = null;

    var i: usize = 0;
    while (i < num_entries) : (i += 1) {
        if (gps_reader.remaining() < 12) break;

        const entry_abs_offset = ifd_offset + 2 + i * 12;

        const tag = try gps_reader.readInt(u16);
        const type_id = try gps_reader.readInt(u16);
        const count = try gps_reader.readInt(u32);
        const inline_or_offset_val = try gps_reader.readInt(u32);

        const type_size = getTypeSize(type_id);
        if (type_size == 0) continue;
        const total_size = @as(u64, count) * type_size;

        var val_reader: ByteReader = undefined;
        if (total_size <= 4) {
            val_reader = ByteReader.init(root_reader.buffer[entry_abs_offset + 8 .. entry_abs_offset + 12], root_reader.endian);
        } else {
            if (total_size > root_reader.buffer.len or inline_or_offset_val > root_reader.buffer.len - total_size) continue;
            val_reader = ByteReader.init(root_reader.buffer[inline_or_offset_val .. inline_or_offset_val + total_size], root_reader.endian);
        }

        switch (tag) {
            1 => { // GPSLatitudeRef
                if (type_id == 2 and count >= 2) {
                    lat_ref = try val_reader.readInt(u8);
                }
            },
            2 => { // GPSLatitude
                if (type_id == 5 and count == 3) {
                    const deg = try val_reader.readRational();
                    const min = try val_reader.readRational();
                    const sec = try val_reader.readRational();
                    lat_val = deg + min / 60.0 + sec / 3600.0;
                }
            },
            3 => { // GPSLongitudeRef
                if (type_id == 2 and count >= 2) {
                    lon_ref = try val_reader.readInt(u8);
                }
            },
            4 => { // GPSLongitude
                if (type_id == 5 and count == 3) {
                    const deg = try val_reader.readRational();
                    const min = try val_reader.readRational();
                    const sec = try val_reader.readRational();
                    lon_val = deg + min / 60.0 + sec / 3600.0;
                }
            },
            else => {},
        }
    }

    if (lat_val) |lat| {
        var val = lat;
        if (lat_ref) |ref| {
            if (ref == 'S' or ref == 's') {
                val = -val;
            }
        }
        meta.gps_latitude = val;
    }
    if (lon_val) |lon| {
        var val = lon;
        if (lon_ref) |ref| {
            if (ref == 'W' or ref == 'w') {
                val = -val;
            }
        }
        meta.gps_longitude = val;
    }
}

/// Parse IFD1 (the thumbnail sub-IFD) from a TIFF byte stream. Reads
/// JPEGInterchangeFormat (0x0201) and JPEGInterchangeFormatLength (0x0202) tags
/// to locate the embedded JPEG thumbnail, validates the SOI marker (0xFF 0xD8),
/// and dupes the bytes into `meta.thumbnail_data`. Called from `parseTiff`,
/// which is invoked for both standalone TIFF files and JPEG EXIF APP1 payloads
/// (see `jpeg.parseJpegFile`). Errors are silenced by the caller; a missing or
/// malformed IFD1 leaves `thumbnail_data` null.
pub fn parseIfd1ForThumbnail(
    allocator: std.mem.Allocator,
    root_reader: *ByteReader,
    ifd1_offset: usize,
    meta: *ImageMetadata,
) !void {
    // Use subtraction-based bounds checking to prevent integer overflow
    if (ifd1_offset == 0 or ifd1_offset >= root_reader.buffer.len or root_reader.buffer.len - ifd1_offset < 2) return;

    var ifd_reader = ByteReader.init(root_reader.buffer[ifd1_offset..], root_reader.endian);
    const num_entries = try ifd_reader.readInt(u16);

    var thumb_offset: ?u32 = null;
    var thumb_length: ?u32 = null;

    var i: usize = 0;
    while (i < num_entries) : (i += 1) {
        if (ifd_reader.remaining() < 12) break;

        const entry_abs_offset = ifd1_offset + 2 + i * 12;

        const tag = try ifd_reader.readInt(u16);
        const type_id = try ifd_reader.readInt(u16);
        const count = try ifd_reader.readInt(u32);
        _ = count;

        var val_reader = ByteReader.init(root_reader.buffer[entry_abs_offset + 8 .. entry_abs_offset + 12], root_reader.endian);

        if (tag == 0x0201) { // JPEGInterchangeFormat
            thumb_offset = if (type_id == 3) try val_reader.readInt(u16) else try val_reader.readInt(u32);
        } else if (tag == 0x0202) { // JPEGInterchangeFormatLength
            thumb_length = if (type_id == 3) try val_reader.readInt(u16) else try val_reader.readInt(u32);
        }
        try ifd_reader.skip(4);
    }

    if (thumb_offset) |offset| {
        if (thumb_length) |length| {
            const offset_uz = @as(usize, offset);
            const length_uz = @as(usize, length);
            // Use subtraction-based bounds checking to prevent integer overflow on offset_uz + length_uz
            if (offset_uz < root_reader.buffer.len and length_uz <= root_reader.buffer.len - offset_uz) {
                const thumb_slice = root_reader.buffer[offset_uz .. offset_uz + length_uz];
                if (thumb_slice.len >= 2 and thumb_slice[0] == 0xff and thumb_slice[1] == 0xd8) {
                    if (meta.thumbnail_data) |old| allocator.free(old);
                    meta.thumbnail_data = try allocator.dupe(u8, thumb_slice);
                }
            }
        }
    }
}

/// Parse a TIFF structure from a byte buffer. Resolves endianness, validates the magic
/// number (42), and reads the initial IFD offset to parse image and EXIF metadata.
pub fn parseTiff(
    allocator: std.mem.Allocator,
    tiff_buf: []const u8,
    meta: *ImageMetadata,
) !void {
    if (tiff_buf.len < 8) return error.TiffTooShort;

    var endian: std.builtin.Endian = .little;
    if (std.mem.eql(u8, tiff_buf[0..2], "II")) {
        endian = .little;
    } else if (std.mem.eql(u8, tiff_buf[0..2], "MM")) {
        endian = .big;
    } else {
        return error.InvalidTiffHeader;
    }

    var reader = ByteReader.init(tiff_buf, endian);
    try reader.skip(2); // Skip II/MM

    const magic = try reader.readInt(u16);
    if (magic != 42) return error.InvalidTiffMagic;

    const first_ifd_offset = try reader.readInt(u32);
    try parseIfd(allocator, &reader, @as(usize, first_ifd_offset), meta, 0);
}

test "parseTiff nested IFD1 thumbnail offset extraction" {
    const allocator = std.testing.allocator;

    var buf = [_]u8{0} ** 60;
    // Header
    buf[0] = 'I';
    buf[1] = 'I';
    buf[2] = 42;
    buf[3] = 0;
    buf[4] = 8;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 0; // First IFD offset = 8

    // IFD0
    buf[8] = 1;
    buf[9] = 0; // 1 entry
    // Entry 0: Tag 0x0112 (Orientation)
    buf[10] = 0x12;
    buf[11] = 0x01;
    buf[12] = 3;
    buf[13] = 0;
    buf[14] = 1;
    buf[15] = 0;
    buf[16] = 0;
    buf[17] = 0;
    buf[18] = 5;
    buf[19] = 0;
    buf[20] = 0;
    buf[21] = 0; // Orientation = 5
    // Next IFD Offset (IFD1 offset) = 26
    buf[22] = 26;
    buf[23] = 0;
    buf[24] = 0;
    buf[25] = 0;

    // IFD1
    buf[26] = 2;
    buf[27] = 0; // 2 entries
    // Entry 0: Tag 0x0201 (JPEGInterchangeFormat)
    buf[28] = 0x01;
    buf[29] = 0x02;
    buf[30] = 4;
    buf[31] = 0;
    buf[32] = 1;
    buf[33] = 0;
    buf[34] = 0;
    buf[35] = 0;
    buf[36] = 56;
    buf[37] = 0;
    buf[38] = 0;
    buf[39] = 0; // Offset = 56
    // Entry 1: Tag 0x0202 (JPEGInterchangeFormatLength)
    buf[40] = 0x02;
    buf[41] = 0x02;
    buf[42] = 4;
    buf[43] = 0;
    buf[44] = 1;
    buf[45] = 0;
    buf[46] = 0;
    buf[47] = 0;
    buf[48] = 4;
    buf[49] = 0;
    buf[50] = 0;
    buf[51] = 0; // Length = 4
    // Next IFD Offset = 0 (offset 52..56)
    buf[52] = 0;
    buf[53] = 0;
    buf[54] = 0;
    buf[55] = 0;

    // Mock JPEG thumbnail data (SOI = 0xff 0xd8)
    buf[56] = 0xff;
    buf[57] = 0xd8;
    buf[58] = 0xff;
    buf[59] = 0xd9;

    var meta = ImageMetadata{
        .format = "tiff",
        .width = 100,
        .height = 100,
    };
    defer meta.deinit(allocator);

    try parseTiff(allocator, &buf, &meta);

    try std.testing.expectEqual(@as(?u16, 5), meta.orientation);
    try std.testing.expect(meta.thumbnail_data != null);
    try std.testing.expectEqual(@as(usize, 4), meta.thumbnail_data.?.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xd8, 0xff, 0xd9 }, meta.thumbnail_data.?);
}
