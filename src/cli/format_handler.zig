const std = @import("std");
const root = @import("../root.zig");
const media_scan = root.media_scan;
const test_utils = @import("../core/test_utils.zig");

pub fn isVideoExtension(ext: []const u8) bool {
    if (ext.len == 0 or ext.len > 16) return false;
    var ext_lower: [16]u8 = undefined;
    const slice = std.ascii.lowerString(ext_lower[0..ext.len], ext);
    for (media_scan.videoExtensions) |ve| {
        if (std.mem.eql(u8, slice, ve)) return true;
    }
    return false;
}

/// Write/check thumbs only under a validated 64-hex content hash. `original_path`
/// remains the ffmpeg `-i` / EXIF source; the disk stem is never path-hashed.
pub fn generateFfmpegThumbnail(io: std.Io, allocator: std.mem.Allocator, ffmpeg_path: []const u8, original_path: []const u8, content_hash_hex: []const u8, thumb_dir: []const u8, is_video: bool) !bool {
    const thumb_path_jpg = root.utils.getThumbnailPath(allocator, thumb_dir, content_hash_hex) catch return false;
    defer allocator.free(thumb_path_jpg);
    root.utils.ensureParentDirAbsolute(io, thumb_path_jpg) catch return false;

    // Content-keying maps duplicate-content files to the same final path, so two
    // workers can run ffmpeg into it concurrently. Write to a per-thread-unique
    // temp sibling (same dir => same filesystem) and atomically rename into place
    // so readers only ever see a complete file (last-writer-wins).
    const tmp_path = std.fmt.allocPrint(allocator, "{s}.{d}.tmp", .{ thumb_path_jpg, std.Thread.getCurrentId() }) catch return false;
    defer allocator.free(tmp_path);
    var renamed = false;
    defer if (!renamed) std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{ ffmpeg_path, "-y", "-nostdin", "-threads", "1" });
    if (is_video) {
        try argv.appendSlice(allocator, &.{ "-skip_frame", "nokey", "-ss", "00:00:01" });
    }
    try argv.appendSlice(allocator, &.{ "-i", original_path });
    if (is_video) {
        // -vframes 1 captures a single frame; -t 10 is a standard output-side
        // time limit that aborts gracefully if the seek or decode stalls.
        try argv.appendSlice(allocator, &.{ "-vframes", "1", "-t", "10", "-update", "1" });
    } else {
        try argv.appendSlice(allocator, &.{ "-update", "1" });
    }
    try argv.appendSlice(allocator, &.{ "-vf", "scale=iw*min(320/iw\\,320/ih):ih*min(320/iw\\,320/ih)", "-f", "image2", tmp_path });

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = try child.wait(io);
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return false;

    std.Io.Dir.renameAbsolute(tmp_path, thumb_path_jpg, io) catch return false;
    renamed = true;
    return true;
}

/// Generate a 2-second, 5fps, 320px animated GIF preview for a video file.
/// Uses ffmpeg's built-in gif encoder (no external library) with a per-clip
/// palettegen/paletteuse pass for good color fidelity. The shared ffmpeg_sem
/// must be held by the caller before this. Disk key is content hash, not path.
pub fn generateFfmpegAnimatedPreview(io: std.Io, allocator: std.mem.Allocator, ffmpeg_path: []const u8, original_path: []const u8, content_hash_hex: []const u8, thumb_dir: []const u8) !bool {
    const preview_path = root.utils.getAnimatedPreviewPath(allocator, thumb_dir, content_hash_hex) catch return false;
    defer allocator.free(preview_path);
    root.utils.ensureParentDirAbsolute(io, preview_path) catch return false;

    // Same temp+rename discipline as generateFfmpegThumbnail: duplicate-content
    // videos map to the same preview path, so generate to a per-thread-unique
    // temp sibling and atomically rename into place (last-writer-wins).
    const tmp_path = std.fmt.allocPrint(allocator, "{s}.{d}.tmp", .{ preview_path, std.Thread.getCurrentId() }) catch return false;
    defer allocator.free(tmp_path);
    var renamed = false;
    defer if (!renamed) std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    // Seek to 1s, capture 3s, no audio.
    // -f gif is explicit because the .tmp output name defeats ffmpeg's
    // extension-based muxer inference (which previously relied on the .gif
    // suffix of the final path).
    try argv.appendSlice(allocator, &.{
        ffmpeg_path,
        "-y",
        "-nostdin",
        "-threads",
        "1",
        "-ss",
        "00:00:01",
        "-t",
        "3",
        "-i",
        original_path,
        "-vf",
        "fps=10,scale=iw*min(320/iw\\,320/ih):ih*min(320/iw\\,320/ih):flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
        "-loop",
        "0",
        "-an",
        "-f",
        "gif",
        tmp_path,
    });

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = try child.wait(io);
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return false;

    std.Io.Dir.renameAbsolute(tmp_path, preview_path, io) catch return false;
    renamed = true;
    return true;
}

pub fn saveThumbnailBytes(io: std.Io, allocator: std.mem.Allocator, content_hash_hex: []const u8, thumb_dir: []const u8, bytes: []const u8) !bool {
    const thumb_path_jpg = root.utils.getThumbnailPath(allocator, thumb_dir, content_hash_hex) catch return false;
    defer allocator.free(thumb_path_jpg);
    root.utils.ensureParentDirAbsolute(io, thumb_path_jpg) catch return false;

    // Write to a per-thread-unique temp sibling then atomically rename, so two
    // workers saving the same content-keyed thumbnail can't tear each other's file.
    const tmp_path = std.fmt.allocPrint(allocator, "{s}.{d}.tmp", .{ thumb_path_jpg, std.Thread.getCurrentId() }) catch return false;
    defer allocator.free(tmp_path);
    var renamed = false;
    defer if (!renamed) std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    {
        const file = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch return false;
        defer std.Io.File.close(file, io);
        try std.Io.File.writePositionalAll(file, io, bytes, 0);
    }

    std.Io.Dir.renameAbsolute(tmp_path, thumb_path_jpg, io) catch return false;
    renamed = true;
    return true;
}

pub fn checkAnimatedPreviewExists(io: std.Io, allocator: std.mem.Allocator, content_hash_hex: []const u8, thumb_dir: []const u8) bool {
    const preview_path = root.utils.getAnimatedPreviewPath(allocator, thumb_dir, content_hash_hex) catch return false;
    defer allocator.free(preview_path);

    const file = std.Io.Dir.openFileAbsolute(io, preview_path, .{ .mode = .read_only }) catch return false;
    std.Io.File.close(file, io);
    return true;
}

pub fn checkThumbnailExists(io: std.Io, allocator: std.mem.Allocator, content_hash_hex: []const u8, thumb_dir: []const u8) bool {
    const thumb_path_jpg = root.utils.getThumbnailPath(allocator, thumb_dir, content_hash_hex) catch return false;
    defer allocator.free(thumb_path_jpg);

    const file = std.Io.Dir.openFileAbsolute(io, thumb_path_jpg, .{ .mode = .read_only }) catch return false;
    std.Io.File.close(file, io);
    return true;
}

test "isVideoExtension boundaries" {
    // Core formats — parsed by native video parser
    try std.testing.expect(isVideoExtension(".mp4"));
    try std.testing.expect(isVideoExtension(".m4v"));
    try std.testing.expect(isVideoExtension(".mov"));
    try std.testing.expect(isVideoExtension(".mkv"));
    try std.testing.expect(isVideoExtension(".webm"));
    // Extended formats — scanned but metadata via ffprobe/duration heuristic
    try std.testing.expect(isVideoExtension(".avi"));
    try std.testing.expect(isVideoExtension(".wmv"));
    try std.testing.expect(isVideoExtension(".flv"));
    // Case-insensitive
    try std.testing.expect(isVideoExtension(".MP4"));
    try std.testing.expect(isVideoExtension(".MKV"));
    // Negatives
    try std.testing.expect(!isVideoExtension(".png"));
    try std.testing.expect(!isVideoExtension(".jpg"));
    try std.testing.expect(!isVideoExtension(".extremelylongextensionnamehere"));
    try std.testing.expect(!isVideoExtension(""));
}

test "rebuild missing thumbnails unit test" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;

    const png_header = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0dIHDR\x00\x00\x02\x80\x00\x00\x01\xe0\x08\x02\x00\x00\x00";
    const filename = "test_rebuild.png";
    const file = try std.Io.Dir.createFile(temp_dir, io, filename, .{});
    try std.Io.File.writePositionalAll(file, io, png_header, 0);
    std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(temp_dir, io, filename) catch {};

    const full_image_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, filename });
    defer allocator.free(full_image_path);

    const db_filename = "test_rebuild.db";
    const full_db_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, db_filename });
    defer allocator.free(full_db_path);
    defer std.Io.Dir.deleteFile(temp_dir, io, db_filename) catch {};

    // Create thumbnail dir
    const thumb_dir_name = "test_rebuild_thumbs";
    const full_thumb_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, thumb_dir_name });
    defer allocator.free(full_thumb_path);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, full_thumb_path);
    defer std.Io.Dir.deleteDir(std.Io.Dir.cwd(), io, full_thumb_path) catch {};

    // Content-keyed stem (fixed 64-hex; same key for any path with this hash)
    const content_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    // 1. Verify checkThumbnailExists returns false since no thumbnail exists yet
    try std.testing.expect(!checkThumbnailExists(io, allocator, content_hash, full_thumb_path));

    // 2. saveThumbnailBytes must create shard parents (aa/bb/) before writing
    const wrote = try saveThumbnailBytes(io, allocator, content_hash, full_thumb_path, "MOCK_THUMB");
    try std.testing.expect(wrote);
    try std.testing.expect(checkThumbnailExists(io, allocator, content_hash, full_thumb_path));

    // 3. Non-hex / synthetic stems must not write under path-hash or synthetic names
    try std.testing.expect(!try saveThumbnailBytes(io, allocator, "nonhexhash", full_thumb_path, "BAD"));
    try std.testing.expect(!checkThumbnailExists(io, allocator, "nonhexhash", full_thumb_path));
}

test "two paths one content hash share one on-disk thumbnail" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();

    const full_thumb_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, "shared_thumbs" });
    defer allocator.free(full_thumb_path);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, full_thumb_path);
    defer std.Io.Dir.deleteDir(std.Io.Dir.cwd(), io, full_thumb_path) catch {};

    const content_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const wrote = try saveThumbnailBytes(io, allocator, content_hash, full_thumb_path, "SHARED_THUMB");
    try std.testing.expect(wrote);

    // Both logical paths resolve to the same content-keyed file.
    try std.testing.expect(checkThumbnailExists(io, allocator, content_hash, full_thumb_path));
    const p1 = try root.utils.getThumbnailPath(allocator, full_thumb_path, content_hash);
    defer allocator.free(p1);
    const p2 = try root.utils.getThumbnailPath(allocator, full_thumb_path, content_hash);
    defer allocator.free(p2);
    try std.testing.expectEqualStrings(p1, p2);
    try std.testing.expect(std.mem.indexOf(u8, p1, "01/23/") != null);
}
