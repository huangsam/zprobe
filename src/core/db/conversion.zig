const std = @import("std");
const db_types = @import("types.zig");
const image_common = @import("../../formats/images/common.zig");
const video_common = @import("../../formats/videos/common.zig");

/// Helper to convert ImageMetadata to DbRecord, allocating strings in the process.
pub fn populateDbRecordFromImage(
    allocator: std.mem.Allocator,
    meta: *const image_common.ImageMetadata,
    path: []const u8,
    size: u64,
    has_thumbnail: bool,
) !db_types.DbRecord {
    var db_record = db_types.DbRecord{
        .path = path,
        .size = size,
        .format = meta.format,
        .width = meta.width,
        .height = meta.height,
        .orientation = meta.orientation,
        .create_time = null,
        .camera_make = null,
        .camera_model = null,
        .gps_latitude = meta.gps_latitude,
        .gps_longitude = meta.gps_longitude,
        .has_thumbnail = has_thumbnail,
    };

    // Single errdefer at the top: if any allocation fails, deinit() will free
    // only the strings that were successfully allocated (Zig's errdefer runs LIFO
    // but deinit() safely handles null/zero values).
    errdefer db_record.deinit(allocator);

    if (meta.create_time) |ct| db_record.create_time = try allocator.dupe(u8, ct);
    if (meta.camera_make) |cm| db_record.camera_make = try allocator.dupe(u8, cm);
    if (meta.camera_model) |cm| db_record.camera_model = try allocator.dupe(u8, cm);

    return db_record;
}

/// Helper to convert VideoInfo to DbRecord.
pub fn populateDbRecordFromVideo(
    allocator: std.mem.Allocator,
    meta: *const video_common.VideoInfo,
    path: []const u8,
    size: u64,
    has_thumbnail: bool,
    has_animated: bool,
) !db_types.DbRecord {
    var db_record = db_types.DbRecord{
        .path = path,
        .size = size,
        .format = meta.format,
        .width = meta.width,
        .height = meta.height,
        .orientation = meta.orientation,
        .create_time = null,
        .camera_make = null,
        .camera_model = null,
        .gps_latitude = null,
        .gps_longitude = null,
        .duration_sec = meta.duration_sec,
        .has_thumbnail = has_thumbnail,
        .has_animated = has_animated,
    };

    // Single errdefer: if allocation fails, deinit() safely handles partial state.
    errdefer db_record.deinit(allocator);

    if (meta.create_time) |ct| db_record.create_time = try allocator.dupe(u8, ct);

    return db_record;
}
