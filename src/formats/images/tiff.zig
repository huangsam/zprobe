const std = @import("std");
const ByteReader = @import("../../core/byte_reader.zig").ByteReader;
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
            if (inline_or_offset_val + total_size > root_reader.buffer.len) continue;
            val_reader = ByteReader.init(root_reader.buffer[inline_or_offset_val .. inline_or_offset_val + total_size], root_reader.endian);
        }

        switch (tag) {
            0x0100 => { // ImageWidth
                if (count == 1) {
                    meta.width = if (type_id == 3) try val_reader.readInt(u16) else try val_reader.readInt(u32);
                }
            },
            0x0101 => { // ImageLength
                if (count == 1) {
                    meta.height = if (type_id == 3) try val_reader.readInt(u16) else try val_reader.readInt(u32);
                }
            },
            0x0112 => { // Orientation
                if (type_id == 3 and count == 1) {
                    meta.orientation = try val_reader.readInt(u16);
                }
            },
            0x010f => { // Make
                if (type_id == 2) {
                    meta.camera_make = try val_reader.readAscii(allocator, count);
                }
            },
            0x0110 => { // Model
                if (type_id == 2) {
                    meta.camera_model = try val_reader.readAscii(allocator, count);
                }
            },
            0x8769 => { // Exif IFD Offset
                if (type_id == 4 and count == 1) {
                    try parseIfd(allocator, root_reader, @as(usize, inline_or_offset_val), meta, depth + 1);
                }
            },
            0x8825 => { // GPS Info IFD Offset
                if (type_id == 4 and count == 1) {
                    try parseGpsIfd(root_reader, @as(usize, inline_or_offset_val), meta);
                }
            },
            0x9003 => { // DateTimeOriginal
                if (type_id == 2) {
                    meta.create_time = try val_reader.readAscii(allocator, count);
                }
            },
            else => {},
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
            if (inline_or_offset_val + total_size > root_reader.buffer.len) continue;
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
