//! Command-line interface for scanning media files and displaying metadata.
//!
//! This file demonstrates:
//! 1. The Zig 0.16.0 `main` entrypoint design using `std.process.Init`.
//! 2. Custom stdout buffering using raw byte arrays.
//! 3. Standard command-line argument processing.
//! 4. Absolute path resolution and heap memory allocation tracking.

const std = @import("std");
const root = @import("root.zig");
const media_scan = root.media_scan;
const image_meta = root.image_meta;
const video_meta = root.video_meta;
const test_utils = @import("core/test_utils.zig");
const db = root.db;
const hashing = root.hashing;

/// Helper to initialize a buffered file writer targeting stdout.
///
/// In Zig 0.16.0, `std.Io.File.Writer` provides buffered output streams
/// wrapping the system output resource.
fn file_writer(io: anytype, buffer: []u8) std.Io.File.Writer {
    return std.Io.File.Writer.init(.stdout(), io, buffer);
}

fn isVideoExtension(ext: []const u8) bool {
    if (ext.len == 0 or ext.len > 16) return false;
    var ext_lower: [16]u8 = undefined;
    const slice = std.ascii.lowerString(ext_lower[0..ext.len], ext);
    for (media_scan.videoExtensions) |ve| {
        if (std.mem.eql(u8, slice, ve)) return true;
    }
    return false;
}

fn formatOrientation(orient: u16) []const u8 {
    return switch (orient) {
        1 => "0° (Normal)",
        2 => "Mirrored Horizontal",
        3 => "180°",
        4 => "Mirrored Vertical",
        5 => "Mirrored 90° CCW",
        6 => "90° CW (Vertical)",
        7 => "Mirrored 90° CW",
        8 => "270° CW",
        else => "Unknown",
    };
}

/// Helper to convert ImageMetadata to DbRecord, allocating strings in the process.
fn populateJsonFromImage(
    allocator: std.mem.Allocator,
    meta: *const image_meta.ImageMetadata,
    path: []const u8,
    size: u64,
    has_thumbnail: bool,
) !db.DbRecord {
    var json_out = db.DbRecord{
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
    errdefer json_out.deinit(allocator);

    if (meta.create_time) |ct| json_out.create_time = try allocator.dupe(u8, ct);
    if (meta.camera_make) |cm| json_out.camera_make = try allocator.dupe(u8, cm);
    if (meta.camera_model) |cm| json_out.camera_model = try allocator.dupe(u8, cm);

    return json_out;
}

/// Helper to convert VideoInfo to DbRecord.
fn populateJsonFromVideo(
    allocator: std.mem.Allocator,
    meta: *const video_meta.VideoInfo,
    path: []const u8,
    size: u64,
    has_thumbnail: bool,
    has_animated: bool,
) !db.DbRecord {
    var json_out = db.DbRecord{
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
    errdefer json_out.deinit(allocator);

    if (meta.create_time) |ct| json_out.create_time = try allocator.dupe(u8, ct);

    return json_out;
}
const WorkerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.File.Writer,
    json_mode: bool,
    entries: []const media_scan.ScanEntry,
    file_index: *std.atomic.Value(usize),
    stdout_mutex: *std.Io.Mutex,
    success_count: *std.atomic.Value(usize),
    db: ?*db.Db = null,
    thumb_dir: ?[]const u8 = null,
    has_ffmpeg: bool = false,
    ffmpeg_sem: ?*std.Io.Semaphore = null,
    rebuild_thumbnails: bool = false,
    animated_previews: bool = false,
    rebuild_previews: bool = false,
    ffmpeg_path: []const u8 = "ffmpeg",
};

fn checkFFmpeg(io: std.Io, ffmpeg_path: []const u8) bool {
    const allocator = std.heap.page_allocator;

    const decoders_res = std.process.run(allocator, io, .{
        .argv = &.{ ffmpeg_path, "-decoders" },
    }) catch return false;
    defer {
        allocator.free(decoders_res.stdout);
        allocator.free(decoders_res.stderr);
    }
    switch (decoders_res.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }

    if (std.mem.indexOf(u8, decoders_res.stdout, "mjpeg") == null) return false;
    if (std.mem.indexOf(u8, decoders_res.stdout, "png") == null) return false;
    if (std.mem.indexOf(u8, decoders_res.stdout, "webp") == null) return false;
    if (std.mem.indexOf(u8, decoders_res.stdout, "h264") == null) return false;

    const encoders_res = std.process.run(allocator, io, .{
        .argv = &.{ ffmpeg_path, "-encoders" },
    }) catch return false;
    defer {
        allocator.free(encoders_res.stdout);
        allocator.free(encoders_res.stderr);
    }
    switch (encoders_res.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }

    if (std.mem.indexOf(u8, encoders_res.stdout, "mjpeg") == null) return false;
    if (std.mem.indexOf(u8, encoders_res.stdout, "gif") == null) return false;

    return true;
}

/// Write/check thumbs only under a validated 64-hex content hash. `original_path`
/// remains the ffmpeg `-i` / EXIF source; the disk stem is never path-hashed.
fn generateFfmpegThumbnail(io: std.Io, allocator: std.mem.Allocator, ffmpeg_path: []const u8, original_path: []const u8, content_hash_hex: []const u8, thumb_dir: []const u8, is_video: bool) !bool {
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
fn generateFfmpegAnimatedPreview(io: std.Io, allocator: std.mem.Allocator, ffmpeg_path: []const u8, original_path: []const u8, content_hash_hex: []const u8, thumb_dir: []const u8) !bool {
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

fn saveThumbnailBytes(io: std.Io, allocator: std.mem.Allocator, content_hash_hex: []const u8, thumb_dir: []const u8, bytes: []const u8) !bool {
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

fn checkAnimatedPreviewExists(io: std.Io, allocator: std.mem.Allocator, content_hash_hex: []const u8, thumb_dir: []const u8) bool {
    const preview_path = root.utils.getAnimatedPreviewPath(allocator, thumb_dir, content_hash_hex) catch return false;
    defer allocator.free(preview_path);

    const file = std.Io.Dir.openFileAbsolute(io, preview_path, .{ .mode = .read_only }) catch return false;
    std.Io.File.close(file, io);
    return true;
}

fn checkThumbnailExists(io: std.Io, allocator: std.mem.Allocator, content_hash_hex: []const u8, thumb_dir: []const u8) bool {
    const thumb_path_jpg = root.utils.getThumbnailPath(allocator, thumb_dir, content_hash_hex) catch return false;
    defer allocator.free(thumb_path_jpg);

    const file = std.Io.Dir.openFileAbsolute(io, thumb_path_jpg, .{ .mode = .read_only }) catch return false;
    std.Io.File.close(file, io);
    return true;
}

const worker = struct {
    fn workerMain(c_ctx: WorkerContext) void {
        while (true) {
            const idx = c_ctx.file_index.fetchAdd(1, .monotonic);
            if (idx >= c_ctx.entries.len) break;

            const entry = c_ctx.entries[idx];
            const ext = media_scan.getExtension(entry.path);
            const is_video = isVideoExtension(ext);

            processFile(c_ctx, entry, is_video) catch {};
        }
    }

    /// Look up an existing record by path. On a hit, if --rebuild-thumbnails or
    /// --animated-previews is set and the corresponding on-disk artifact is
    /// missing, returns null AND sets force_regen so the caller skips the
    /// content-hash reuse path and regenerates the artifact via parseMediaFile.
    /// Existence checks use content-keyed paths from the row's file_hash.
    fn queryCacheRecord(c_ctx: WorkerContext, path: []const u8, size: u64, mtime: i64, is_video: bool, allocator: std.mem.Allocator, force_regen: *bool) ?db.DbRecord {
        force_regen.* = false;
        const d = c_ctx.db orelse return null;
        d.lockRead(c_ctx.io);
        defer d.unlockRead(c_ctx.io);
        const cache_res = d.queryCache(allocator, path, size, mtime) catch |err| {
            std.debug.print("Warning: cache query failed: {s}\n", .{@errorName(err)});
            return null;
        };

        if (cache_res.hit) {
            const content_hash: ?[]const u8 = if (cache_res.json_out.file_hash) |fh|
                if (root.utils.isValidContentHash(fh)) fh else null
            else
                null;

            if (c_ctx.rebuild_thumbnails and c_ctx.thumb_dir != null) {
                const missing = content_hash == null or !checkThumbnailExists(c_ctx.io, allocator, content_hash.?, c_ctx.thumb_dir.?);
                if (missing) {
                    force_regen.* = true;
                    return null;
                }
            }
            // Animated preview (re)generation for videos. Two modes, mirroring the
            // thumbnail flags: --rebuild-previews heals by on-disk existence (like
            // --rebuild-thumbnails), so a deleted gif is regenerated regardless of
            // the has_animated flag; plain --animated-previews only back-fills
            // videos that never had one (flag-based), staying cheap on converged
            // libraries by not stat-ing every gif each scan. Gated on is_video:
            // previews are only ever generated for videos.
            if (is_video and c_ctx.animated_previews and c_ctx.thumb_dir != null) {
                const on_disk = content_hash != null and checkAnimatedPreviewExists(c_ctx.io, allocator, content_hash.?, c_ctx.thumb_dir.?);
                const missing = if (c_ctx.rebuild_previews)
                    !on_disk
                else
                    !cache_res.json_out.has_animated and !on_disk;
                if (missing) {
                    force_regen.* = true;
                    return null;
                }
            }
            return cache_res.json_out;
        }
        return null;
    }

    /// Content-hash hit for a new path. Never trust has_thumbnail/has_animated alone:
    /// always stat the content-keyed artifact; generate if missing when possible;
    /// demote shared-row flags if the content file is still absent after attempts.
    fn queryHashRecord(c_ctx: WorkerContext, path: []const u8, size: u64, mtime: i64, file_hash: []const u8, is_video: bool, allocator: std.mem.Allocator) ?db.DbRecord {
        const d = c_ctx.db orelse return null;
        var record: ?db.DbRecord = null;
        {
            d.lockRead(c_ctx.io);
            defer d.unlockRead(c_ctx.io);
            record = d.queryMetadataByHash(allocator, path, file_hash) catch return null;
        }

        if (record) |*rec| {
            rec.size = size;

            if (c_ctx.thumb_dir) |thumb_dir| {
                if (root.utils.isValidContentHash(file_hash)) {
                    var has_thumb = checkThumbnailExists(c_ctx.io, allocator, file_hash, thumb_dir);
                    var has_animated = if (is_video and c_ctx.animated_previews)
                        checkAnimatedPreviewExists(c_ctx.io, allocator, file_hash, thumb_dir)
                    else
                        rec.has_animated;

                    if ((!has_thumb or (is_video and c_ctx.animated_previews and !has_animated)) and c_ctx.has_ffmpeg) {
                        if (c_ctx.ffmpeg_sem) |sem| sem.waitUncancelable(c_ctx.io);
                        defer if (c_ctx.ffmpeg_sem) |sem| sem.post(c_ctx.io);
                        if (!has_thumb) {
                            has_thumb = generateFfmpegThumbnail(c_ctx.io, allocator, c_ctx.ffmpeg_path, path, file_hash, thumb_dir, is_video) catch false;
                        }
                        if (is_video and c_ctx.animated_previews and !has_animated) {
                            has_animated = generateFfmpegAnimatedPreview(c_ctx.io, allocator, c_ctx.ffmpeg_path, path, file_hash, thumb_dir) catch false;
                        }
                    }

                    // A duplicate-content worker may have produced the shared artifact
                    // via temp+rename after our check/failed generation. Re-stat before
                    // recording so we never demote a row a sibling path just populated.
                    if (!has_thumb)
                        has_thumb = checkThumbnailExists(c_ctx.io, allocator, file_hash, thumb_dir);
                    if (is_video and c_ctx.animated_previews and !has_animated)
                        has_animated = checkAnimatedPreviewExists(c_ctx.io, allocator, file_hash, thumb_dir);

                    // Align returned flags with disk evidence (never claim present without a file).
                    rec.has_thumbnail = has_thumb;
                    if (is_video and c_ctx.animated_previews) {
                        rec.has_animated = has_animated;
                    }
                } else {
                    // Non-hex hash: no content-keyed path; do not claim thumbs.
                    rec.has_thumbnail = false;
                    if (is_video) rec.has_animated = false;
                }
            }

            // Insert duplicate media path to DB since we matched by hash but not path
            {
                d.lockWrite(c_ctx.io);
                defer d.unlockWrite(c_ctx.io);
                d.insertMedia(c_ctx.io, rec, mtime) catch |err| {
                    std.debug.print("Warning: failed to insert duplicate media path to DB: {s}\n", .{@errorName(err)});
                };
                // insertMedia uses MAX() on flags; force demote when disk is actually missing.
                if (!rec.has_thumbnail) {
                    d.updateHasThumbnail(path, false) catch {};
                }
                if (is_video and c_ctx.animated_previews and !rec.has_animated) {
                    d.updateHasAnimated(path, false) catch {};
                }
            }
            return rec.*;
        }
        return null;
    }

    fn parseMediaFile(c_ctx: WorkerContext, path: []const u8, size: u64, is_video: bool, file_hash: ?[]const u8, allocator: std.mem.Allocator) !db.DbRecord {
        var has_thumb = false;
        var has_animated = false;
        var record: db.DbRecord = undefined;

        // Disk keys require a real 64-hex computeFastHash. Never fall back to path-hash
        // or insertMedia synthetic signatures for thumb/preview stems.
        const content_hash: ?[]const u8 = if (file_hash) |fh|
            if (root.utils.isValidContentHash(fh)) fh else null
        else
            null;

        if (is_video) {
            var res = try video_meta.getVideoMetadata(allocator, path, c_ctx.io);
            if (c_ctx.thumb_dir) |thumb_dir| {
                if (content_hash) |ch| {
                    has_thumb = checkThumbnailExists(c_ctx.io, allocator, ch, thumb_dir);
                    if (c_ctx.animated_previews) {
                        has_animated = checkAnimatedPreviewExists(c_ctx.io, allocator, ch, thumb_dir);
                    }

                    if ((!has_thumb or (c_ctx.animated_previews and !has_animated)) and c_ctx.has_ffmpeg) {
                        if (c_ctx.ffmpeg_sem) |sem| sem.waitUncancelable(c_ctx.io);
                        defer if (c_ctx.ffmpeg_sem) |sem| sem.post(c_ctx.io);
                        if (!has_thumb) {
                            has_thumb = generateFfmpegThumbnail(c_ctx.io, allocator, c_ctx.ffmpeg_path, path, ch, thumb_dir, true) catch false;
                        }
                        if (c_ctx.animated_previews and !has_animated) {
                            has_animated = generateFfmpegAnimatedPreview(c_ctx.io, allocator, c_ctx.ffmpeg_path, path, ch, thumb_dir) catch false;
                        }
                    }

                    // Sibling path may have filled the shared content-keyed artifact via
                    // temp+rename after our check/failed generation. Re-stat so flags
                    // (and insertMedia MAX) reflect disk, not just this worker's attempt.
                    if (!has_thumb)
                        has_thumb = checkThumbnailExists(c_ctx.io, allocator, ch, thumb_dir);
                    if (c_ctx.animated_previews and !has_animated)
                        has_animated = checkAnimatedPreviewExists(c_ctx.io, allocator, ch, thumb_dir);
                }
            }
            record = try populateJsonFromVideo(allocator, &res, path, size, has_thumb, has_animated);
        } else {
            var res = try image_meta.parseFile(allocator, path, c_ctx.io);
            if (c_ctx.thumb_dir) |thumb_dir| {
                if (content_hash) |ch| {
                    has_thumb = checkThumbnailExists(c_ctx.io, allocator, ch, thumb_dir);
                    if (!has_thumb) {
                        if (res.thumbnail_data) |thumb_bytes| {
                            has_thumb = saveThumbnailBytes(c_ctx.io, allocator, ch, thumb_dir, thumb_bytes) catch false;
                        } else if (c_ctx.has_ffmpeg) {
                            if (c_ctx.ffmpeg_sem) |sem| sem.waitUncancelable(c_ctx.io);
                            defer if (c_ctx.ffmpeg_sem) |sem| sem.post(c_ctx.io);
                            has_thumb = generateFfmpegThumbnail(c_ctx.io, allocator, c_ctx.ffmpeg_path, path, ch, thumb_dir, false) catch false;
                        }
                    }

                    // Same sibling re-stat as the video branch / queryHashRecord
                    if (!has_thumb)
                        has_thumb = checkThumbnailExists(c_ctx.io, allocator, ch, thumb_dir);
                }
            }
            record = try populateJsonFromImage(allocator, &res, path, size, has_thumb);
        }

        if (file_hash) |fh| {
            record.file_hash = try allocator.dupe(u8, fh);
        }

        return record;
    }

    fn saveRecordToDb(c_ctx: WorkerContext, record: *const db.DbRecord, mtime: i64) void {
        const d = c_ctx.db orelse return;
        d.lockWrite(c_ctx.io);
        defer d.unlockWrite(c_ctx.io);
        d.insertMedia(c_ctx.io, record, mtime) catch |err| {
            std.debug.print("Warning: failed to insert media to DB: {s}\n", .{@errorName(err)});
        };
    }

    fn printMetadataRecord(c_ctx: WorkerContext, json_out: db.DbRecord, fsize: u64) !void {
        c_ctx.stdout_mutex.lockUncancelable(c_ctx.io);
        defer c_ctx.stdout_mutex.unlock(c_ctx.io);

        _ = c_ctx.success_count.fetchAdd(1, .monotonic);

        const interface = &c_ctx.out.interface;

        if (c_ctx.json_mode) {
            try std.json.fmt(json_out, .{}).format(interface);
            try interface.print("\n", .{});
        } else {
            try interface.print("   {s} ({d} bytes)\n", .{ json_out.path, fsize });
            try interface.print("    Format: {s}\n", .{json_out.format});
            try interface.print("    Dimensions: {d} x {d}\n", .{ json_out.width.?, json_out.height.? });
            if (json_out.orientation) |orient| {
                try interface.print("    Orientation: {s}\n", .{formatOrientation(orient)});
            }
            if (json_out.create_time) |ct| {
                try interface.print("    Captured: {s}\n", .{ct});
            }
            if (json_out.camera_make) |make| {
                try interface.print("    Camera Make: {s}\n", .{make});
            }
            if (json_out.camera_model) |model| {
                try interface.print("    Camera Model: {s}\n", .{model});
            }
            if (json_out.gps_latitude) |lat| {
                if (json_out.gps_longitude) |lon| {
                    const lat_ref: u8 = if (lat >= 0) 'N' else 'S';
                    const lon_ref: u8 = if (lon >= 0) 'E' else 'W';
                    try interface.print("    GPS: {d:.4}° {c}, {d:.4}° {c}\n", .{
                        @abs(lat), lat_ref, @abs(lon), lon_ref,
                    });
                }
            }
            if (json_out.duration_sec) |dur| {
                try interface.print("    Duration: {d:.2} sec\n", .{dur});
            }
            try interface.print("\n", .{});
        }
    }

    fn processFile(c_ctx: WorkerContext, entry: media_scan.ScanEntry, is_video: bool) !void {
        const file = std.Io.Dir.openFileAbsolute(c_ctx.io, entry.path, .{ .mode = .read_only }) catch |err| {
            c_ctx.stdout_mutex.lockUncancelable(c_ctx.io);
            defer c_ctx.stdout_mutex.unlock(c_ctx.io);
            c_ctx.out.flush() catch {};
            std.debug.print("Warning: failed to open '{s}': {s}\n", .{ entry.path, @errorName(err) });
            return;
        };
        defer std.Io.File.close(file, c_ctx.io);

        const st = std.Io.File.stat(file, c_ctx.io) catch |err| {
            c_ctx.stdout_mutex.lockUncancelable(c_ctx.io);
            defer c_ctx.stdout_mutex.unlock(c_ctx.io);
            c_ctx.out.flush() catch {};
            std.debug.print("Warning: failed to get stat of '{s}': {s}\n", .{ entry.path, @errorName(err) });
            return;
        };
        const fsize = st.size;
        const mtime = @as(i64, @intCast(st.mtime.nanoseconds));

        var arena = std.heap.ArenaAllocator.init(c_ctx.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // 1. Try DB path cache query
        var force_regen = false;
        if (queryCacheRecord(c_ctx, entry.path, fsize, mtime, is_video, arena_allocator, &force_regen)) |record| {
            try printMetadataRecord(c_ctx, record, fsize);
            return;
        }

        // 2. Compute fast hash
        var file_hash: ?[]const u8 = null;
        if (hashing.computeFastHash(c_ctx.io, arena_allocator, entry.path)) |hash| {
            file_hash = hash;
        } else |err| {
            std.debug.print("Warning: failed to compute fast hash for '{s}': {s}\n", .{ entry.path, @errorName(err) });
        }

        // 3. Try DB hash query (to reuse metadata from duplicates).
        // Skipped on a forced regen: the path already exists and would match its
        // own content hash here, returning the stale record and defeating the
        // thumbnail/preview back-fill before parseMediaFile can regenerate it.
        if (!force_regen) {
            if (file_hash) |hash| {
                if (queryHashRecord(c_ctx, entry.path, fsize, mtime, hash, is_video, arena_allocator)) |record| {
                    try printMetadataRecord(c_ctx, record, fsize);
                    return;
                }
            }
        }

        // 4. Parse the file manually and generate thumbnails
        const record = parseMediaFile(c_ctx, entry.path, fsize, is_video, file_hash, arena_allocator) catch |err| {
            c_ctx.stdout_mutex.lockUncancelable(c_ctx.io);
            defer c_ctx.stdout_mutex.unlock(c_ctx.io);
            c_ctx.out.flush() catch {};
            const media_type = if (is_video) "video" else "image";
            std.debug.print("Warning: failed to parse {s} '{s}': {s}\n", .{ media_type, entry.path, @errorName(err) });
            return;
        };

        // 5. Store new record in DB
        saveRecordToDb(c_ctx, &record, mtime);

        // 6. Print record metadata
        try printMetadataRecord(c_ctx, record, fsize);
    }
};

fn printHelp(out: anytype, exe_name: []const u8) !void {
    try out.print(
        \\zprobe - Media header scanning and metadata indexing tool
        \\
        \\Usage:
        \\  {s} [options] <directory>...
        \\
        \\Options:
        \\  -h, --help                 Show this help message and exit
        \\  --json                     Output metadata in JSON lines format
        \\  --db <database>            Path to SQLite database for metadata caching and indexing
        \\  -j, --concurrency <n>      Number of concurrent worker threads (default: CPU-based dynamic clamp 8-16)
        \\  --no-thumbnails            Bypass generating and saving thumbnails (useful on slow NAS / 1GB RAM)
        \\  --rebuild-thumbnails       Re-generate missing thumbnails during scanning
        \\  --animated-previews        Generate animated GIF hover previews for videos (2s, 5fps, 320px)
        \\  --rebuild-previews         Re-generate missing animated GIF previews during scanning (implies --animated-previews)
        \\  --prune                    Prune stale cache entries from DB for paths inside scanned directories but no longer present on disk
        \\  --ffmpeg-path <path>       Custom path/command for FFmpeg executable (default: ZPROBE_FFMPEG_PATH env or "ffmpeg")
        \\
        \\Supported Formats:
        \\  Images: JPEG, PNG, GIF, BMP, WebP, TIFF, AVIF, ICO, JXL
        \\  Videos: MP4, M4V, MOV, WebM, MKV, AVI, WMV, FLV
        \\
    , .{exe_name});
}

/// Main application entrypoint.
///
/// In Zig 0.16.0, `main` receives an `init` structure of type `std.process.Init`
/// containing the system I/O context and general purpose allocator (GPA) initialized
/// by the runtime startup code.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Create a stdout writer with a 4KB buffer.
    var io_buf: [4096]u8 = undefined;
    var f_writer = file_writer(io, &io_buf);
    const out = &f_writer.interface;

    // Get command-line args using the GPA allocator.
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    var json_mode = false;
    var target_db: []const u8 = "";
    var show_help = false;
    var target_dirs: std.ArrayList([]const u8) = .empty;
    defer target_dirs.deinit(allocator);
    var concurrency_override: ?usize = null;
    var no_thumbnails = false;
    var rebuild_thumbnails = false;
    var animated_previews = false;
    var rebuild_previews = false;
    var prune_mode = false;
    var ffmpeg_path_override: ?[]const u8 = null;

    var arg_idx: usize = 1;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--no-thumbnails")) {
            no_thumbnails = true;
        } else if (std.mem.eql(u8, arg, "--rebuild-thumbnails")) {
            rebuild_thumbnails = true;
        } else if (std.mem.eql(u8, arg, "--animated-previews")) {
            animated_previews = true;
        } else if (std.mem.eql(u8, arg, "--rebuild-previews")) {
            // Rebuilding previews implies generating them.
            rebuild_previews = true;
            animated_previews = true;
        } else if (std.mem.eql(u8, arg, "--prune")) {
            prune_mode = true;
        } else if (std.mem.eql(u8, arg, "--ffmpeg-path")) {
            if (arg_idx + 1 < args.len) {
                arg_idx += 1;
                ffmpeg_path_override = args[arg_idx];
            } else {
                try out.print("Error: --ffmpeg-path option requires a value\n", .{});
                try out.flush();
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--concurrency") or std.mem.eql(u8, arg, "-j")) {
            if (arg_idx + 1 < args.len) {
                arg_idx += 1;
                const val = args[arg_idx];
                const parsed = std.fmt.parseInt(usize, val, 10) catch {
                    try out.print("Error: Invalid concurrency value '{s}'\n", .{val});
                    try out.flush();
                    std.process.exit(1);
                };
                if (parsed == 0) {
                    try out.print("Error: Concurrency must be at least 1\n", .{});
                    try out.flush();
                    std.process.exit(1);
                }
                concurrency_override = parsed;
            } else {
                try out.print("Error: --concurrency/-j option requires a value\n", .{});
                try out.flush();
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--db")) {
            if (arg_idx + 1 < args.len) {
                arg_idx += 1;
                target_db = args[arg_idx];
            } else {
                try out.print("Error: --db option requires a database path\n", .{});
                try out.flush();
                return;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else {
            try target_dirs.append(allocator, arg);
        }
    }

    if (show_help or args.len < 2) {
        try printHelp(out, args[0]);
        try out.flush();
        return;
    }

    if (target_dirs.items.len == 0) {
        try out.print("Error: No directories specified\n", .{});
        try out.flush();
        return;
    }

    const env_ffmpeg = init.environ_map.get("ZPROBE_FFMPEG_PATH");
    const ffmpeg_path = if (ffmpeg_path_override) |path| path else (if (env_ffmpeg) |path| path else "ffmpeg");

    const has_ffmpeg = if (no_thumbnails) false else checkFFmpeg(io, ffmpeg_path);
    if (!json_mode and !no_thumbnails) {
        if (has_ffmpeg) {
            std.debug.print("FFmpeg detected and validated: {s}\n", .{ffmpeg_path});
        } else {
            std.debug.print("Warning: FFmpeg not found or invalid at '{s}'. Video and fallback image thumbnails will be skipped.\n", .{ffmpeg_path});
        }
    }

    // Initialize Database if path is provided
    var database: db.Db = undefined;
    var db_ptr: ?*db.Db = null;
    var thumb_dir_path: ?[]const u8 = null;
    defer if (thumb_dir_path) |p| allocator.free(p);

    if (target_db.len > 0) {
        database = try db.Db.init(allocator, target_db);
        db_ptr = &database;
        database.beginTransaction();

        if (!no_thumbnails) {
            // Resolve absolute DB directory to create .zprobe_thumbnails next to it
            const cwd = std.Io.Dir.cwd();
            const dir = std.fs.path.dirname(target_db) orelse ".";
            const abs_dir = cwd.realPathFileAlloc(io, dir, allocator) catch null;
            defer if (abs_dir) |path| allocator.free(path);
            const resolved_dir = if (abs_dir) |path| path else dir;
            const abs_db = try std.fs.path.join(allocator, &.{ resolved_dir, std.fs.path.basename(target_db) });
            defer allocator.free(abs_db);

            const db_dir = std.fs.path.dirname(abs_db) orelse ".";
            thumb_dir_path = try std.fs.path.join(allocator, &.{ db_dir, ".zprobe_thumbnails" });

            std.Io.Dir.createDirPath(cwd, io, thumb_dir_path.?) catch |err| {
                if (err != error.PathAlreadyExists and err != error.DirExists) {
                    std.debug.print("Warning: failed to create thumbnail directory: {s}\n", .{@errorName(err)});
                }
            };
        }
    }
    defer {
        if (db_ptr) |d| {
            d.deinit();
        }
    }

    var all_entries: std.ArrayList(media_scan.ScanEntry) = .empty;
    errdefer {
        for (all_entries.items) |entry| {
            allocator.free(entry.path);
        }
        all_entries.deinit(allocator);
    }

    // Directories whose scan returned at least one entry. Only these are eligible
    // for pruning: a directory that yielded nothing (unmounted, inaccessible, etc.)
    // must not have its cache entries deleted, because that would be a false positive.
    var prunable_dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (prunable_dirs.items) |d| {
            allocator.free(d);
        }
        prunable_dirs.deinit(allocator);
    }

    const cwd = std.Io.Dir.cwd();
    for (target_dirs.items) |dir_path| {
        const abs_dir = cwd.realPathFileAlloc(io, dir_path, allocator) catch |err| {
            try out.print("Error: Failed to resolve path '{s}': {s}\n", .{ dir_path, @errorName(err) });
            try out.flush();
            return;
        };
        defer allocator.free(abs_dir);

        if (!json_mode) {
            std.debug.print("Scanning: {s}\n", .{dir_path});
        }

        var scan_res = try media_scan.scan(abs_dir, io, allocator);
        errdefer {
            for (scan_res.entries.items) |entry| {
                allocator.free(entry.path);
            }
            scan_res.entries.deinit(allocator);
        }

        if (scan_res.degraded and !json_mode) {
            std.debug.print("Warning: Scan of '{s}' was degraded due to errors; pruning will be skipped for this directory.\n", .{dir_path});
        }

        if (!scan_res.degraded and scan_res.entries.items.len > 0) {
            const dup = try allocator.dupe(u8, abs_dir);
            try prunable_dirs.append(allocator, dup);
        }

        try all_entries.appendSlice(allocator, scan_res.entries.items);
        scan_res.entries.deinit(allocator);
    }

    if (!json_mode) {
        std.debug.print("\n", .{});
    }

    defer {
        for (all_entries.items) |entry| {
            allocator.free(entry.path);
        }
        all_entries.deinit(allocator);
    }

    var file_index = std.atomic.Value(usize).init(0);
    var stdout_mutex = std.Io.Mutex.init;
    var success_count = std.atomic.Value(usize).init(0);

    const cpu_count = std.Thread.getCpuCount() catch 4;
    const num_workers = if (concurrency_override) |override| override else root.utils.computeWorkerCount(cpu_count);

    const threads = try allocator.alloc(std.Thread, num_workers);
    defer allocator.free(threads);

    var ffmpeg_concurrency = root.utils.computeFfmpegConcurrency(cpu_count, num_workers);
    if (init.environ_map.get("ZPROBE_FFMPEG_WORKER_COUNT")) |env_val| {
        if (std.fmt.parseInt(usize, env_val, 10)) |val| {
            if (val > 0) {
                ffmpeg_concurrency = val;
            }
        } else |_| {}
    }
    var ffmpeg_sem: std.Io.Semaphore = .{ .permits = ffmpeg_concurrency };

    const worker_ctx = WorkerContext{
        .allocator = allocator,
        .io = io,
        .out = &f_writer,
        .json_mode = json_mode,
        .entries = all_entries.items,
        .file_index = &file_index,
        .stdout_mutex = &stdout_mutex,
        .success_count = &success_count,
        .db = db_ptr,
        .thumb_dir = thumb_dir_path,
        .has_ffmpeg = has_ffmpeg,
        .ffmpeg_sem = &ffmpeg_sem,
        .rebuild_thumbnails = rebuild_thumbnails,
        .animated_previews = animated_previews,
        .rebuild_previews = rebuild_previews,
        .ffmpeg_path = ffmpeg_path,
    };

    var spawned_count: usize = 0;
    defer {
        for (threads[0..spawned_count]) |t| {
            t.join();
        }
    }

    for (0..num_workers) |k| {
        threads[k] = try std.Thread.spawn(.{}, worker.workerMain, .{worker_ctx});
        spawned_count += 1;
    }

    for (threads[0..spawned_count]) |t| {
        t.join();
    }
    spawned_count = 0;

    // Run pruning pass if requested. Only prune within directories that produced
    // entries this run, so a degraded scan cannot wipe its cached entries.
    if (prune_mode and db_ptr != null and prunable_dirs.items.len > 0) {
        const d = db_ptr.?;
        var active_paths = std.StringHashMap(void).init(allocator);
        defer active_paths.deinit();
        for (all_entries.items) |entry| {
            try active_paths.put(entry.path, {});
        }

        const pruned_count = try d.pruneStalePaths(io, prunable_dirs.items, &active_paths);
        if (pruned_count > 0 and !json_mode) {
            std.debug.print("Pruned {d} stale cache entries\n", .{pruned_count});
        }
    }

    // Commit transaction
    if (db_ptr) |d| {
        d.commitTransaction(io);
    }

    try out.flush();

    if (!json_mode) {
        std.debug.print("Found {d} media file(s)\n", .{all_entries.items.len});
    }
}

test "concurrent file processing integration test" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;

    // Create 50 mock PNG files
    const png_header = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0dIHDR\x00\x00\x02\x80\x00\x00\x01\xe0\x08\x02\x00\x00\x00";
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var filename_buf: [32]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, "image_{d}.png", .{i});
        const file = try std.Io.Dir.createFile(temp_dir, io, filename, .{});
        defer std.Io.File.close(file, io);
        try std.Io.File.writePositionalAll(file, io, png_header, 0);
    }

    // Defer file deletion
    defer {
        var j: usize = 0;
        while (j < 50) : (j += 1) {
            var filename_buf: [32]u8 = undefined;
            const filename = std.fmt.bufPrint(&filename_buf, "image_{d}.png", .{j}) catch continue;
            std.Io.Dir.deleteFile(temp_dir, io, filename) catch {};
        }
    }

    // Scan
    var scan_res = try media_scan.scan(temp_ctx.abs_path, io, allocator);
    defer {
        for (scan_res.entries.items) |entry| {
            allocator.free(entry.path);
        }
        scan_res.entries.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 50), scan_res.entries.items.len);

    // Spawn workers
    var file_index = std.atomic.Value(usize).init(0);
    var stdout_mutex = std.Io.Mutex.init;
    var success_count = std.atomic.Value(usize).init(0);

    const out_filename = "test_output.txt";
    const out_file = try std.Io.Dir.createFile(temp_dir, io, out_filename, .{});
    defer {
        std.Io.File.close(out_file, io);
        std.Io.Dir.deleteFile(temp_dir, io, out_filename) catch {};
    }

    var io_buf: [1024]u8 = undefined;
    var f_writer = std.Io.File.Writer.init(out_file, io, &io_buf);

    const worker_ctx = WorkerContext{
        .allocator = allocator,
        .io = io,
        .out = &f_writer,
        .json_mode = false,
        .entries = scan_res.entries.items,
        .file_index = &file_index,
        .stdout_mutex = &stdout_mutex,
        .success_count = &success_count,
        .thumb_dir = null,
        .has_ffmpeg = false,
    };

    const num_workers = 8;
    var threads: [num_workers]std.Thread = undefined;
    var spawned_count: usize = 0;
    defer {
        for (threads[0..spawned_count]) |t| {
            t.join();
        }
    }

    for (0..num_workers) |k| {
        threads[k] = try std.Thread.spawn(.{}, worker.workerMain, .{worker_ctx});
        spawned_count += 1;
    }

    for (threads[0..spawned_count]) |t| {
        t.join();
    }
    spawned_count = 0;

    try f_writer.flush();

    // Verify all 50 files were parsed successfully
    try std.testing.expectEqual(@as(usize, 50), success_count.load(.monotonic));
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

test "sqlite db caching integration test" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();
    const temp_dir = temp_ctx.tmp.dir;

    // Create 1 mock PNG file
    const png_header = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0dIHDR\x00\x00\x02\x80\x00\x00\x01\xe0\x08\x02\x00\x00\x00";
    const filename = "cached_image.png";
    const file = try std.Io.Dir.createFile(temp_dir, io, filename, .{});
    try std.Io.File.writePositionalAll(file, io, png_header, 0);
    std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(temp_dir, io, filename) catch {};

    // Get full path of cached_image.png
    const full_image_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, filename });
    defer allocator.free(full_image_path);

    // Setup SQLite DB file
    const db_filename = "test_cache.db";
    const full_db_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, db_filename });
    defer allocator.free(full_db_path);
    defer std.Io.Dir.deleteFile(temp_dir, io, db_filename) catch {};

    var database = try db.Db.init(allocator, full_db_path);
    defer database.deinit();

    // Scan
    var scan_res = try media_scan.scan(temp_ctx.abs_path, io, allocator);
    defer {
        for (scan_res.entries.items) |entry| {
            allocator.free(entry.path);
        }
        scan_res.entries.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), scan_res.entries.items.len);

    const out_filename = "test_output.txt";
    const out_file = try std.Io.Dir.createFile(temp_dir, io, out_filename, .{});
    defer {
        std.Io.File.close(out_file, io);
        std.Io.Dir.deleteFile(temp_dir, io, out_filename) catch {};
    }

    var io_buf: [256]u8 = undefined;
    var f_writer = std.Io.File.Writer.init(out_file, io, &io_buf);

    var file_index = std.atomic.Value(usize).init(0);
    var stdout_mutex = std.Io.Mutex.init;
    var success_count = std.atomic.Value(usize).init(0);

    const worker_ctx = WorkerContext{
        .allocator = allocator,
        .io = io,
        .out = &f_writer,
        .json_mode = false,
        .entries = scan_res.entries.items,
        .file_index = &file_index,
        .stdout_mutex = &stdout_mutex,
        .success_count = &success_count,
        .db = &database,
        .thumb_dir = null,
        .has_ffmpeg = false,
    };

    // First Run (should parse & cache)
    worker.processFile(worker_ctx, scan_res.entries.items[0], false) catch |err| {
        std.debug.print("First run processFile failed: {s}\n", .{@errorName(err)});
        return err;
    };
    try f_writer.flush();
    try std.testing.expectEqual(@as(usize, 1), success_count.load(.monotonic));

    // Verify row is in DB by querying cache
    // Get file stat to obtain current mtime
    const file_for_stat_first = try std.Io.Dir.openFileAbsolute(io, full_image_path, .{ .mode = .read_only });
    const st_first = try std.Io.File.stat(file_for_stat_first, io);
    const mtime_first = @as(i64, @intCast(st_first.mtime.nanoseconds));
    std.Io.File.close(file_for_stat_first, io);

    const cache_res_first = try database.queryCache(allocator, full_image_path, png_header.len, mtime_first);
    try std.testing.expect(cache_res_first.hit);
    try std.testing.expectEqualStrings("png", cache_res_first.json_out.format);
    allocator.free(cache_res_first.json_out.format);
    cache_res_first.json_out.deinit(allocator);

    // Corrupt the file on disk (overwrite with invalid data)
    const corrupt_file = try std.Io.Dir.createFile(temp_dir, io, filename, .{});
    try std.Io.File.writePositionalAll(corrupt_file, io, "INVALID_PNG_HEADER", 0);
    // Keep size same by writing padding
    var pad: [24]u8 = undefined;
    @memset(&pad, 0);
    try std.Io.File.writePositionalAll(corrupt_file, io, &pad, 18);
    std.Io.File.close(corrupt_file, io);

    // Get the new file stat, and update the DB row's mtime to match the new mtime
    const file_for_stat = try std.Io.Dir.openFileAbsolute(io, full_image_path, .{ .mode = .read_only });
    const st_corrupt = try std.Io.File.stat(file_for_stat, io);
    const new_size = st_corrupt.size;
    const new_mtime = @as(i64, @intCast(st_corrupt.mtime.nanoseconds));
    std.Io.File.close(file_for_stat, io);

    // Insert the new record with the updated mtime and size to simulate cache hit
    const updated_record = db.DbRecord{
        .path = full_image_path,
        .size = new_size,
        .format = "png",
        .width = 640,
        .height = 480,
    };
    try database.insertMedia(io, &updated_record, new_mtime);

    // Reset loop index & success counter
    file_index.store(0, .monotonic);
    success_count.store(0, .monotonic);

    // Second Run (should cache hit and NOT fail on the corrupted PNG!)
    worker.processFile(worker_ctx, scan_res.entries.items[0], false) catch |err| {
        std.debug.print("Second run processFile failed: {s}\n", .{@errorName(err)});
        return err;
    };
    try f_writer.flush();

    // If it successfully hits the cache, it won't parse the file and will succeed!
    try std.testing.expectEqual(@as(usize, 1), success_count.load(.monotonic));
}

test "CLI options integration check" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Check if the binary exists, if not, skip the test
    const cwd = std.Io.Dir.cwd();
    const abs_bin_path = cwd.realPathFileAlloc(io, "./zig-out/bin/zprobe", allocator) catch {
        // Skip test if binary not built yet
        return;
    };
    defer allocator.free(abs_bin_path);

    const bin_file = std.Io.Dir.openFileAbsolute(io, abs_bin_path, .{ .mode = .read_only }) catch {
        return;
    };
    std.Io.File.close(bin_file, io);

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();

    const png_header = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0dIHDR\x00\x00\x02\x80\x00\x00\x01\xe0\x08\x02\x00\x00\x00";
    const file = try std.Io.Dir.createFile(temp_ctx.tmp.dir, io, "img.png", .{});
    try std.Io.File.writePositionalAll(file, io, png_header, 0);
    std.Io.File.close(file, io);
    defer std.Io.Dir.deleteFile(temp_ctx.tmp.dir, io, "img.png") catch {};

    const db_path = "test_cli.db";
    const full_db_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, db_path });
    defer allocator.free(full_db_path);
    defer std.Io.Dir.deleteFile(temp_ctx.tmp.dir, io, db_path) catch {};

    // Run with -j 1 and --no-thumbnails
    const run_res = try std.process.run(allocator, io, .{
        .argv = &.{ abs_bin_path, "-j", "1", "--no-thumbnails", "--db", full_db_path, temp_ctx.abs_path },
    });
    defer {
        allocator.free(run_res.stdout);
        allocator.free(run_res.stderr);
    }

    try std.testing.expectEqual(@as(u32, 0), switch (run_res.term) {
        .exited => |code| code,
        else => 99,
    });

    // Verify thumbnail directory was NOT created
    const thumb_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, ".zprobe_thumbnails" });
    defer allocator.free(thumb_path);
    const thumb_exists = if (std.Io.Dir.openDirAbsolute(io, thumb_path, .{})) |d| blk: {
        std.Io.Dir.close(d, io);
        break :blk true;
    } else |_| false;

    try std.testing.expect(!thumb_exists);
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

    var database = try db.Db.init(allocator, full_db_path);
    defer database.deinit();

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

test "Db.pruneStalePaths pruning logic" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer tmp_ctx.cleanup();

    const path = try std.fmt.allocPrint(allocator, "{s}/prune_test.db", .{tmp_ctx.abs_path});
    defer allocator.free(path);

    var database = try db.Db.init(allocator, path);
    defer database.deinit();

    // Insert two files
    const rec1 = db.DbRecord{
        .path = "/photos/a.jpg",
        .size = 100,
        .format = "jpeg",
    };
    const rec2 = db.DbRecord{
        .path = "/videos/b.mp4",
        .size = 200,
        .format = "mp4",
    };

    try database.insertMedia(io, &rec1, 10);
    try database.insertMedia(io, &rec2, 20);

    // Build active paths containing only a.jpg
    var active_paths = std.StringHashMap(void).init(allocator);
    defer active_paths.deinit();
    try active_paths.put("/photos/a.jpg", {});

    // Target dirs to check: we scan /photos and /videos
    var target_dirs: std.ArrayList([]const u8) = .empty;
    defer target_dirs.deinit(allocator);
    try target_dirs.append(allocator, "/photos");
    try target_dirs.append(allocator, "/videos");

    // Prune: b.mp4 is in /videos (which is in target_dirs) but not in active_paths. a.jpg is in active_paths.
    // So b.mp4 should be pruned, and a.jpg should remain.
    const pruned_count = try database.pruneStalePaths(io, target_dirs.items, &active_paths);
    try std.testing.expectEqual(@as(u32, 1), pruned_count);

    // Verify b.mp4 is deleted, a.jpg remains
    const hit_a = try database.queryCache(allocator, "/photos/a.jpg", 100, 10);
    defer if (hit_a.hit) {
        hit_a.json_out.deinit(allocator);
        allocator.free(hit_a.json_out.format);
    };
    try std.testing.expect(hit_a.hit);

    const hit_b = try database.queryCache(allocator, "/videos/b.mp4", 200, 20);
    defer if (hit_b.hit) {
        hit_b.json_out.deinit(allocator);
        allocator.free(hit_b.json_out.format);
    };
    try std.testing.expect(!hit_b.hit);
}

test "Db.pruneStalePaths skips directories excluded by the guardrail" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer tmp_ctx.cleanup();

    const path = try std.fmt.allocPrint(allocator, "{s}/prune_guardrail_test.db", .{tmp_ctx.abs_path});
    defer allocator.free(path);

    var database = try db.Db.init(allocator, path);
    defer database.deinit();

    const rec1 = db.DbRecord{ .path = "/photos/a.jpg", .size = 100, .format = "jpeg" };
    const rec2 = db.DbRecord{ .path = "/videos/b.mp4", .size = 200, .format = "mp4" };
    try database.insertMedia(io, &rec1, 10);
    try database.insertMedia(io, &rec2, 20);

    // Simulate a degraded scan: /videos returned zero entries this run, so the
    // guardrail leaves it out of the prunable list.
    var active_paths = std.StringHashMap(void).init(allocator);
    defer active_paths.deinit();
    try active_paths.put("/photos/a.jpg", {});

    var prunable_dirs: std.ArrayList([]const u8) = .empty;
    defer prunable_dirs.deinit(allocator);
    try prunable_dirs.append(allocator, "/photos");

    // b.mp4 is absent from active_paths but lives under the excluded /videos directory, so it
    // must survive the pruning pass. Nothing under /photos is stale, so nothing should be pruned.
    const pruned_count = try database.pruneStalePaths(io, prunable_dirs.items, &active_paths);
    try std.testing.expectEqual(@as(u32, 0), pruned_count);

    const hit_b = try database.queryCache(allocator, "/videos/b.mp4", 200, 20);
    defer if (hit_b.hit) {
        hit_b.json_out.deinit(allocator);
        allocator.free(hit_b.json_out.format);
    };
    try std.testing.expect(hit_b.hit);
}

extern fn chmod(path: [*:0]const u8, mode: u32) c_int;

test "main CLI scan: degraded scan disables pruning" {
    if (comptime @import("builtin").os.tag == .windows) return;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer tmp_ctx.cleanup();

    const temp_dir = tmp_ctx.tmp.dir;

    const db_filename = "degraded_prune_test.db";
    const full_db_path = try std.fs.path.join(allocator, &.{ tmp_ctx.abs_path, db_filename });
    defer allocator.free(full_db_path);
    defer std.Io.Dir.deleteFile(temp_dir, io, db_filename) catch {};

    var database = try db.Db.init(allocator, full_db_path);
    defer database.deinit();

    const healthy_img = try std.fs.path.join(allocator, &.{ tmp_ctx.abs_path, "photo.jpg" });
    defer allocator.free(healthy_img);
    const rec1 = db.DbRecord{ .path = healthy_img, .size = 100, .format = "jpeg" };
    try database.insertMedia(io, &rec1, 10);

    const unreadable_subdir = try std.fs.path.join(allocator, &.{ tmp_ctx.abs_path, "unreadable" });
    defer allocator.free(unreadable_subdir);
    const stale_img = try std.fs.path.join(allocator, &.{ unreadable_subdir, "stale.jpg" });
    defer allocator.free(stale_img);
    const rec2 = db.DbRecord{ .path = stale_img, .size = 200, .format = "jpeg" };
    try database.insertMedia(io, &rec2, 20);

    const f1 = try std.Io.Dir.createFile(temp_dir, io, "photo.jpg", .{});
    std.Io.File.close(f1, io);

    try std.Io.Dir.createDirPath(temp_dir, io, "unreadable");
    const f2 = try std.Io.Dir.createFile(temp_dir, io, "unreadable/stale.jpg", .{});
    std.Io.File.close(f2, io);

    const unreadable_path_z = try allocator.dupeZ(u8, unreadable_subdir);
    defer allocator.free(unreadable_path_z);

    const res = chmod(unreadable_path_z.ptr, 0);
    try std.testing.expectEqual(@as(c_int, 0), res);
    defer {
        _ = chmod(unreadable_path_z.ptr, 0o755);
    }

    var scan_res = try media_scan.scan(tmp_ctx.abs_path, io, allocator);
    defer {
        for (scan_res.entries.items) |entry| allocator.free(entry.path);
        scan_res.entries.deinit(allocator);
    }

    try std.testing.expect(scan_res.degraded);

    var prunable_dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (prunable_dirs.items) |d| allocator.free(d);
        prunable_dirs.deinit(allocator);
    }

    if (!scan_res.degraded and scan_res.entries.items.len > 0) {
        const dup = try allocator.dupe(u8, tmp_ctx.abs_path);
        try prunable_dirs.append(allocator, dup);
    }

    var active_paths = std.StringHashMap(void).init(allocator);
    defer active_paths.deinit();
    for (scan_res.entries.items) |entry| {
        try active_paths.put(entry.path, {});
    }

    const pruned_count = try database.pruneStalePaths(io, prunable_dirs.items, &active_paths);
    try std.testing.expectEqual(@as(u32, 0), pruned_count);

    const hit_healthy = try database.queryCache(allocator, healthy_img, 100, 10);
    defer if (hit_healthy.hit) {
        hit_healthy.json_out.deinit(allocator);
        allocator.free(hit_healthy.json_out.format);
    };
    try std.testing.expect(hit_healthy.hit);

    const hit_stale = try database.queryCache(allocator, stale_img, 200, 20);
    defer if (hit_stale.hit) {
        hit_stale.json_out.deinit(allocator);
        allocator.free(hit_stale.json_out.format);
    };
    try std.testing.expect(hit_stale.hit);
}

test "Db.pruneStalePaths trailing slash and absolute paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer tmp_ctx.cleanup();

    const path = try std.fmt.allocPrint(allocator, "{s}/prune_slash_test.db", .{tmp_ctx.abs_path});
    defer allocator.free(path);

    var database = try db.Db.init(allocator, path);
    defer database.deinit();

    // Insert paths simulating absolute/relative and trailing slashes
    const rec1 = db.DbRecord{
        .path = "/photos/a.jpg",
        .size = 100,
        .format = "jpeg",
    };
    const rec2 = db.DbRecord{
        .path = "/photos_backup/b.jpg",
        .size = 200,
        .format = "jpeg",
    };
    const rec3 = db.DbRecord{
        .path = "/videos/c.mp4",
        .size = 300,
        .format = "mp4",
    };

    try database.insertMedia(io, &rec1, 10);
    try database.insertMedia(io, &rec2, 20);
    try database.insertMedia(io, &rec3, 30);

    // Active paths: none are active (we want to see what is pruned)
    var active_paths = std.StringHashMap(void).init(allocator);
    defer active_paths.deinit();

    // Target dirs:
    // 1. "/photos/" (trailing slash) - should prune /photos/a.jpg
    // 2. "/photos" (no trailing slash but prefix of "/photos_backup") - should NOT prune /photos_backup/b.jpg
    // 3. "/videos" (no trailing slash) - should prune /videos/c.mp4
    var target_dirs: std.ArrayList([]const u8) = .empty;
    defer target_dirs.deinit(allocator);
    try target_dirs.append(allocator, "/photos/");
    try target_dirs.append(allocator, "/videos");

    const pruned_count = try database.pruneStalePaths(io, target_dirs.items, &active_paths);
    // Should prune /photos/a.jpg and /videos/c.mp4, but NOT /photos_backup/b.jpg
    try std.testing.expectEqual(@as(u32, 2), pruned_count);

    // Verify /photos/a.jpg is deleted
    const hit_a = try database.queryCache(allocator, "/photos/a.jpg", 100, 10);
    try std.testing.expect(!hit_a.hit);

    // Verify /photos_backup/b.jpg remains
    const hit_b = try database.queryCache(allocator, "/photos_backup/b.jpg", 200, 20);
    defer if (hit_b.hit) {
        hit_b.json_out.deinit(allocator);
        allocator.free(hit_b.json_out.format);
    };
    try std.testing.expect(hit_b.hit);

    // Verify /videos/c.mp4 is deleted
    const hit_c = try database.queryCache(allocator, "/videos/c.mp4", 300, 30);
    try std.testing.expect(!hit_c.hit);
}
