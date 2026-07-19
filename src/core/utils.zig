const std = @import("std");

/// True when `hex` is a 64-char lowercase hex stem (computeFastHash / file_hash form).
/// Used for content-keyed thumbnail paths; synthetic insertMedia signatures are rejected.
pub fn isValidContentHash(hex: []const u8) bool {
    if (hex.len != 64) return false;
    for (hex) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

/// Layout: `thumb_dir/aa/bb/<64-hex content hash>.ext` (two-level shard for FS perf).
/// `content_hash_hex` must be a validated 64-hex stem; returns error.InvalidContentHash otherwise.
fn getShardedMediaPath(allocator: std.mem.Allocator, thumb_dir: []const u8, content_hash_hex: []const u8, ext: []const u8) ![]const u8 {
    if (!isValidContentHash(content_hash_hex)) return error.InvalidContentHash;
    return try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/{s}.{s}", .{
        thumb_dir,
        content_hash_hex[0..2],
        content_hash_hex[2..4],
        content_hash_hex,
        ext,
    });
}

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

/// Derive the unique absolute thumbnail path from a 64-hex content hash and thumbnails directory.
pub fn getThumbnailPath(allocator: std.mem.Allocator, thumb_dir: []const u8, content_hash_hex: []const u8) ![]const u8 {
    return getShardedMediaPath(allocator, thumb_dir, content_hash_hex, "jpg");
}

test "computeWorkerCount boundaries" {
    try std.testing.expectEqual(@as(usize, 8), computeWorkerCount(1));
    try std.testing.expectEqual(@as(usize, 8), computeWorkerCount(2));
    try std.testing.expectEqual(@as(usize, 12), computeWorkerCount(3));
    try std.testing.expectEqual(@as(usize, 16), computeWorkerCount(4));
    try std.testing.expectEqual(@as(usize, 16), computeWorkerCount(8));
    try std.testing.expectEqual(@as(usize, 16), computeWorkerCount(16));
}

test "isValidContentHash" {
    try std.testing.expect(isValidContentHash("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!isValidContentHash("0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF")); // uppercase
    try std.testing.expect(!isValidContentHash("abc")); // too short
    try std.testing.expect(!isValidContentHash("100_123_jpeg_640_480")); // synthetic insertMedia form
}

test "getThumbnailPath derivation" {
    const allocator = std.testing.allocator;
    const thumb_dir = "/tmp/thumbs";
    const content_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const path = try getThumbnailPath(allocator, thumb_dir, content_hash);
    defer allocator.free(path);

    try std.testing.expectEqualStrings(
        "/tmp/thumbs/01/23/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.jpg",
        path,
    );

    try std.testing.expectError(error.InvalidContentHash, getThumbnailPath(allocator, thumb_dir, "not-a-hash"));
}

/// Derive the unique absolute animated GIF preview path from a 64-hex content hash.
/// `anim_dir` is the animations root (`.zprobe_animations`), separate from the
/// thumbnails root. Same shard layout as getThumbnailPath but with a .gif extension.
pub fn getAnimatedPreviewPath(allocator: std.mem.Allocator, anim_dir: []const u8, content_hash_hex: []const u8) ![]const u8 {
    return getShardedMediaPath(allocator, anim_dir, content_hash_hex, "gif");
}

test "getAnimatedPreviewPath derivation" {
    const allocator = std.testing.allocator;
    // Animations live under their own root, distinct from the thumbnails root.
    const anim_dir = "/tmp/anims";
    const content_hash_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const path = try getAnimatedPreviewPath(allocator, anim_dir, content_hash_hex);
    defer allocator.free(path);

    try std.testing.expectEqualStrings(
        "/tmp/anims/01/23/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.gif",
        path,
    );
}

/// Ensure the parent directory of an absolute media path exists (idempotent).
/// Required before writing sharded paths: ffmpeg and createFile do not mkdir parents.
pub fn ensureParentDirAbsolute(io: std.Io, absolute_path: []const u8) !void {
    const parent = std.fs.path.dirname(absolute_path) orelse return;
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, parent);
}

/// Determine FFmpeg worker pool size: floor(cpu_count / 4), at least 1, and never
/// more than the total worker thread count (`num_workers`).
pub fn computeFfmpegConcurrency(cpu_count: usize, num_workers: usize) usize {
    return @max(@min(cpu_count / 4, num_workers), 1);
}

test "computeFfmpegConcurrency scenarios" {
    // 1-core machine, 32 workers -> 1 permit
    try std.testing.expectEqual(@as(usize, 1), computeFfmpegConcurrency(1, 32));
    // 2-core machine, 32 workers -> 1 permit
    try std.testing.expectEqual(@as(usize, 1), computeFfmpegConcurrency(2, 32));
    // 4-core machine, 32 workers -> 1 permit
    try std.testing.expectEqual(@as(usize, 1), computeFfmpegConcurrency(4, 32));
    // 8-core machine, 32 workers -> 2 permits
    try std.testing.expectEqual(@as(usize, 2), computeFfmpegConcurrency(8, 32));
    // 32-core machine, 32 workers -> 8 permits
    try std.testing.expectEqual(@as(usize, 8), computeFfmpegConcurrency(32, 32));
    // 16-core machine, but manually overridden to 2 worker threads -> 2 permits
    try std.testing.expectEqual(@as(usize, 2), computeFfmpegConcurrency(16, 2));
}
