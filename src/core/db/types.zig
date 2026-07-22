const std = @import("std");
const c = @import("../db.zig").c;

/// Represents a media metadata row stored in the database.
pub const DbRecord = struct {
    path: []const u8,
    size: u64,
    format: []const u8,
    width: ?u32 = null,
    height: ?u32 = null,
    orientation: ?u16 = null,
    create_time: ?[]const u8 = null,
    camera_make: ?[]const u8 = null,
    camera_model: ?[]const u8 = null,
    gps_latitude: ?f64 = null,
    gps_longitude: ?f64 = null,
    duration_sec: ?f64 = null,
    has_thumbnail: bool = false,
    has_animated: bool = false,
    file_hash: ?[]const u8 = null,
    notes: ?[]const u8 = null,

    /// Free heap-allocated strings stored within DbRecord.
    pub fn deinit(self: *const DbRecord, allocator: std.mem.Allocator) void {
        if (self.create_time) |s| allocator.free(s);
        if (self.camera_make) |s| allocator.free(s);
        if (self.camera_model) |s| allocator.free(s);
        if (self.file_hash) |s| allocator.free(s);
        if (self.notes) |s| allocator.free(s);
    }
};

/// Result returned from checking the cache.
pub const CacheResult = struct {
    hit: bool,
    db_record: DbRecord = undefined,
};

/// Holds aggregated statistics for dashboard charts and metrics.
pub const DbStats = struct {
    total_files: u32,
    total_size: u64,
    num_images: u32,
    num_videos: u32,
    image_formats: []const FormatCount,
    video_formats: []const FormatCount,
    cameras: []const CameraCount,
    image_sizes: SizeTiers,
    video_sizes: SizeTiers,
    video_durations: DurationTiers,

    pub const FormatCount = struct {
        format: []const u8,
        count: u32,
    };

    pub const CameraCount = struct {
        make: []const u8,
        model: []const u8,
        count: u32,
    };

    pub const SizeTiers = struct {
        tier1: u32,
        tier2: u32,
        tier3: u32,
        tier4: u32,
        tier5: u32,
    };

    pub const DurationTiers = struct {
        tier1: u32,
        tier2: u32,
        tier3: u32,
        tier4: u32,
        tier5: u32,
    };

    pub fn deinit(self: DbStats, allocator: std.mem.Allocator) void {
        for (self.image_formats) |item| allocator.free(item.format);
        allocator.free(self.image_formats);
        for (self.video_formats) |item| allocator.free(item.format);
        allocator.free(self.video_formats);
        for (self.cameras) |item| {
            allocator.free(item.make);
            allocator.free(item.model);
        }
        allocator.free(self.cameras);
    }
};

/// Canonical SQL format list — must mirror media_scan.videoExtensions.
/// is_video_pred_m is the single authority for "what is a video" at the query
/// layer; keep this list in sync with videoExtensions in media_scan.zig.
pub const video_formats_sql = "'mp4', 'm4v', 'webm', 'mkv', 'mov', 'avi', 'wmv', 'flv'";
pub const is_image_pred_m = "(m.duration_sec IS NULL AND m.format NOT IN (" ++ video_formats_sql ++ "))";
pub const is_video_pred_m = "(m.duration_sec IS NOT NULL OR m.format IN (" ++ video_formats_sql ++ "))";

/// Stats cache TTL — short enough to reflect crawler writes, long enough to absorb dashboard polling.
pub const stats_cache_ttl_ns: i96 = 2 * std.time.ns_per_s;

pub const PagedResult = struct {
    total: u32,
    records: []DbRecord,
};
