const std = @import("std");

/// Convert epoch seconds to a civil time string formatted as "YYYY-MM-DD HH:MM:SS".
/// Leverages Howard Hinnant's civil time algorithm (unsigned variant).
pub fn formatEpoch(allocator: std.mem.Allocator, epoch_secs: u64) ![]const u8 {
    const seconds_in_day = 86400;
    const days = epoch_secs / seconds_in_day;
    const seconds_of_day = epoch_secs % seconds_in_day;

    const hour = seconds_of_day / 3600;
    const minute = (seconds_of_day % 3600) / 60;
    const second = seconds_of_day % 60;

    // Civil time algorithm (Howard Hinnant, unsigned variant)
    const z = days + 719468;
    const era = z / 146097;
    const doe = z - era * 146097;
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;

    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year, m, d, hour, minute, second,
    });
}

/// Normalize EXIF-style timestamps ("YYYY:MM:DD HH:MM:SS") to sortable
/// "YYYY-MM-DD HH:MM:SS". Returns a dupe of input when already normalized.
pub fn normalizeDateTime(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len >= 10 and input[4] == ':' and input[7] == ':') {
        var out = try allocator.dupe(u8, input);
        out[4] = '-';
        out[7] = '-';
        return out;
    }
    return try allocator.dupe(u8, input);
}

test "normalizeDateTime converts EXIF colons to dashes" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeDateTime(allocator, "2026:06:27 10:15:30");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("2026-06-27 10:15:30", normalized);

    const already = try normalizeDateTime(allocator, "2024-08-04 21:00:57");
    defer allocator.free(already);
    try std.testing.expectEqualStrings("2024-08-04 21:00:57", already);
}

/// Determine concurrency pool size clamped between 8 and 16 based on core count.
pub fn computeWorkerCount(cpu_count: usize) usize {
    return @min(@max(cpu_count * 4, 8), 16);
}

/// Derive the unique absolute thumbnail path from the original path and the thumbnails directory.
pub fn getThumbnailPath(allocator: std.mem.Allocator, thumb_dir: []const u8, original_path: []const u8) ![]const u8 {
    var hash_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(original_path, &hash_bytes, .{});
    const hex_hash = std.fmt.bytesToHex(hash_bytes, .lower);
    var filename_buf: [68]u8 = undefined;
    const filename = try std.fmt.bufPrint(&filename_buf, "{s}.jpg", .{&hex_hash});
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ thumb_dir, filename });
}

test "computeWorkerCount boundaries" {
    try std.testing.expectEqual(@as(usize, 8), computeWorkerCount(1));
    try std.testing.expectEqual(@as(usize, 8), computeWorkerCount(2));
    try std.testing.expectEqual(@as(usize, 12), computeWorkerCount(3));
    try std.testing.expectEqual(@as(usize, 16), computeWorkerCount(4));
    try std.testing.expectEqual(@as(usize, 16), computeWorkerCount(8));
    try std.testing.expectEqual(@as(usize, 16), computeWorkerCount(16));
}

test "getThumbnailPath derivation" {
    const allocator = std.testing.allocator;
    const thumb_dir = "/tmp/thumbs";
    const original_path = "/path/to/media.png";
    const path = try getThumbnailPath(allocator, thumb_dir, original_path);
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/tmp/thumbs/29b626657cf45e36a163312ad9f9af664135c75efa79f87d238c4a52b9ba9585.jpg", path);
}

/// Derive the unique absolute animated GIF preview path from the original path and thumbnails directory.
/// Uses the same sha256(original_path) hash as getThumbnailPath but with a .gif extension.
pub fn getAnimatedPreviewPath(allocator: std.mem.Allocator, thumb_dir: []const u8, original_path: []const u8) ![]const u8 {
    var hash_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(original_path, &hash_bytes, .{});
    const hex_hash = std.fmt.bytesToHex(hash_bytes, .lower);
    var filename_buf: [68]u8 = undefined; // 64 hex chars + ".gif"
    const filename = try std.fmt.bufPrint(&filename_buf, "{s}.gif", .{&hex_hash});
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ thumb_dir, filename });
}

test "getAnimatedPreviewPath derivation" {
    const allocator = std.testing.allocator;
    const thumb_dir = "/tmp/thumbs";
    const original_path = "/path/to/media.mp4";
    const path = try getAnimatedPreviewPath(allocator, thumb_dir, original_path);
    defer allocator.free(path);

    // Confirm the animated preview path has a .gif extension, in the same directory
    try std.testing.expect(std.mem.endsWith(u8, path, ".gif"));
    try std.testing.expect(std.mem.startsWith(u8, path, thumb_dir));
}

/// Determine FFmpeg worker pool size by allocating half of available CPU cores,
/// clamping between 1 and 4, and ensuring it does not exceed total thread workers.
pub fn computeFfmpegConcurrency(cpu_count: usize, num_workers: usize) usize {
    var count = cpu_count / 2;
    if (count < 1) count = 1;
    if (count > 4) count = 4;
    return @min(count, num_workers);
}

test "computeFfmpegConcurrency scenarios" {
    // 1-core machine, 8 workers -> 1 permit
    try std.testing.expectEqual(@as(usize, 1), computeFfmpegConcurrency(1, 8));
    // 2-core machine, 8 workers -> 1 permit
    try std.testing.expectEqual(@as(usize, 1), computeFfmpegConcurrency(2, 8));
    // 4-core machine, 16 workers -> 2 permits
    try std.testing.expectEqual(@as(usize, 2), computeFfmpegConcurrency(4, 16));
    // 8-core machine, 16 workers -> 4 permits
    try std.testing.expectEqual(@as(usize, 4), computeFfmpegConcurrency(8, 16));
    // 32-core machine, 16 workers -> capped at 4 permits
    try std.testing.expectEqual(@as(usize, 4), computeFfmpegConcurrency(32, 16));
    // 8-core machine, but manually overridden to 2 worker threads -> capped at 2 permits
    try std.testing.expectEqual(@as(usize, 2), computeFfmpegConcurrency(8, 2));
}
