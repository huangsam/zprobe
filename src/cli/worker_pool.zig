const std = @import("std");
const root = @import("../root.zig");
const media_scan = root.media_scan;
const image_meta = root.image_meta;
const video_meta = root.video_meta;
const cli = root.cli;
const db = root.db;
const hashing = root.hashing;
const test_utils = @import("../core/test_utils.zig");

pub const WorkerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.File.Writer,
    json_mode: bool,
    entries: []const media_scan.ScanEntry,
    file_index: *std.atomic.Value(usize),
    stdout_mutex: *std.Io.Mutex,
    success_count: *std.atomic.Value(usize),
    db: ?*db.Db = null,
    thumbnails: cli.ArtifactMode = .on,
    animations: cli.ArtifactMode = .off,
    thumb_dir: ?[]const u8 = null, // .zprobe_thumbnails root
    anim_dir: ?[]const u8 = null, // .zprobe_animations root
    has_ffmpeg: bool = false,
    ffmpeg_sem: ?*std.Io.Semaphore = null,
    ffmpeg_path: []const u8 = "ffmpeg",
};

pub const worker = struct {
    pub fn workerMain(c_ctx: WorkerContext) void {
        while (true) {
            const idx = c_ctx.file_index.fetchAdd(1, .monotonic);
            if (idx >= c_ctx.entries.len) break;

            const entry = c_ctx.entries[idx];
            const ext = media_scan.getExtension(entry.path);
            const is_video = cli.format_handler.isVideoExtension(ext);

            processFile(c_ctx, entry, is_video) catch {};
        }
    }

    /// Look up an existing record by path. On a hit, if a managed artifact needs
    /// healing under its own root, returns null AND sets force_regen so the caller
    /// skips the content-hash reuse path and regenerates via parseMediaFile.
    /// Existence checks use content-keyed paths from the row's file_hash.
    ///
    /// Force-regen fidelity (per artifact):
    ///   thumbnails=on      → never force here (backfill happens in parse/hash-hit)
    ///   thumbnails=rebuild → force when the .jpg is missing under thumb_dir
    ///   animations=on      → force when !has_animated && the .gif is missing under anim_dir
    ///   animations=rebuild → force when the .gif is missing under anim_dir
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

            // Thumbnail rebuild logic
            if (c_ctx.thumbnails.healsFromDisk()) {
                if (c_ctx.thumb_dir) |thumb_dir| {
                    const missing = content_hash == null or !cli.format_handler.checkThumbnailExists(c_ctx.io, allocator, content_hash.?, thumb_dir);
                    if (missing) {
                        force_regen.* = true;
                        return null;
                    }
                }
            }
            // Animation rebuild logic
            if (is_video and c_ctx.animations.generates()) {
                if (c_ctx.anim_dir) |anim_dir| {
                    const on_disk = content_hash != null and cli.format_handler.checkAnimatedPreviewExists(c_ctx.io, allocator, content_hash.?, anim_dir);
                    const missing = if (c_ctx.animations.healsFromDisk())
                        !on_disk
                    else
                        !cache_res.json_out.has_animated and !on_disk;
                    if (missing) {
                        force_regen.* = true;
                        return null;
                    }
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

            const manage_thumb = c_ctx.thumb_dir != null;
            const manage_anim = is_video and c_ctx.anim_dir != null;

            if (manage_thumb or manage_anim) {
                if (root.utils.isValidContentHash(file_hash)) {
                    var has_thumb = if (c_ctx.thumb_dir) |thumb_dir|
                        cli.format_handler.checkThumbnailExists(c_ctx.io, allocator, file_hash, thumb_dir)
                    else
                        rec.has_thumbnail;
                    var has_animated = if (manage_anim)
                        cli.format_handler.checkAnimatedPreviewExists(c_ctx.io, allocator, file_hash, c_ctx.anim_dir.?)
                    else
                        rec.has_animated;

                    const need_thumb_gen = manage_thumb and !has_thumb;
                    const need_anim_gen = manage_anim and !has_animated;
                    if ((need_thumb_gen or need_anim_gen) and c_ctx.has_ffmpeg) {
                        if (c_ctx.ffmpeg_sem) |sem| sem.waitUncancelable(c_ctx.io);
                        defer if (c_ctx.ffmpeg_sem) |sem| sem.post(c_ctx.io);
                        if (need_thumb_gen) {
                            has_thumb = cli.format_handler.generateFfmpegThumbnail(c_ctx.io, allocator, c_ctx.ffmpeg_path, path, file_hash, c_ctx.thumb_dir.?, is_video) catch false;
                        }
                        if (need_anim_gen) {
                            has_animated = cli.format_handler.generateFfmpegAnimatedPreview(c_ctx.io, allocator, c_ctx.ffmpeg_path, path, file_hash, c_ctx.anim_dir.?) catch false;
                        }
                    }

                    // A duplicate-content worker may have produced the shared artifact
                    // via temp+rename after our check/failed generation. Re-stat before
                    // recording so we never demote a row a sibling path just populated.
                    if (manage_thumb and !has_thumb)
                        has_thumb = cli.format_handler.checkThumbnailExists(c_ctx.io, allocator, file_hash, c_ctx.thumb_dir.?);
                    if (manage_anim and !has_animated)
                        has_animated = cli.format_handler.checkAnimatedPreviewExists(c_ctx.io, allocator, file_hash, c_ctx.anim_dir.?);

                    // Align managed flags with disk evidence (never claim present without a file).
                    if (manage_thumb) rec.has_thumbnail = has_thumb;
                    if (manage_anim) rec.has_animated = has_animated;
                }
            } else {
                // Non-hex hash: no content-keyed path; do not claim managed artifacts.
                if (manage_thumb) rec.has_thumbnail = false;
                if (manage_anim) rec.has_animated = false;
            }

            // Insert duplicate media path to DB since we matched by hash but not path
            {
                d.lockWrite(c_ctx.io);
                defer d.unlockWrite(c_ctx.io);
                d.insertMedia(c_ctx.io, rec, mtime) catch |err| {
                    std.debug.print("Warning: failed to insert duplicate media path to DB: {s}\n", .{@errorName(err)});
                };
                // insertMedia uses MAX() on flags; force demote when disk is actually
                // missing - but only for artifacts this run manages, so an `off` mode
                // never demotes the other artifact's flag.
                if (manage_thumb and !rec.has_thumbnail) {
                    d.updateHasThumbnail(path, false) catch {};
                }
                if (manage_anim and !rec.has_animated) {
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
            if (content_hash) |ch| {
                const manage_thumb = c_ctx.thumb_dir != null;
                const manage_anim = c_ctx.anim_dir != null;
                if (manage_thumb) has_thumb = cli.format_handler.checkThumbnailExists(c_ctx.io, allocator, ch, c_ctx.thumb_dir.?);
                if (manage_anim) has_animated = cli.format_handler.checkAnimatedPreviewExists(c_ctx.io, allocator, ch, c_ctx.anim_dir.?);

                const need_thumb_gen = manage_thumb and !has_thumb;
                const need_anim_gen = manage_anim and !has_animated;

                if ((need_thumb_gen or need_anim_gen) and c_ctx.has_ffmpeg) {
                    if (c_ctx.ffmpeg_sem) |sem| sem.waitUncancelable(c_ctx.io);
                    defer if (c_ctx.ffmpeg_sem) |sem| sem.post(c_ctx.io);
                    if (need_thumb_gen) {
                        has_thumb = cli.format_handler.generateFfmpegThumbnail(c_ctx.io, allocator, c_ctx.ffmpeg_path, path, ch, c_ctx.thumb_dir.?, true) catch false;
                    }
                    if (need_anim_gen) {
                        has_animated = cli.format_handler.generateFfmpegAnimatedPreview(c_ctx.io, allocator, c_ctx.ffmpeg_path, path, ch, c_ctx.anim_dir.?) catch false;
                    }
                }

                // Sibling path may have filled the shared content-keyed artifact via
                // temp+rename after our check/failed generation. Re-stat so flags
                // (and insertMedia MAX) reflect disk, not just this worker's attempt.
                if (manage_thumb and !has_thumb)
                    has_thumb = cli.format_handler.checkThumbnailExists(c_ctx.io, allocator, ch, c_ctx.thumb_dir.?);
                if (manage_anim and !has_animated)
                    has_animated = cli.format_handler.checkAnimatedPreviewExists(c_ctx.io, allocator, ch, c_ctx.anim_dir.?);
            }
            record = try db.populateJsonFromVideo(allocator, &res, path, size, has_thumb, has_animated);
        } else {
            var res = try image_meta.parseFile(allocator, path, c_ctx.io);
            if (c_ctx.thumb_dir) |thumb_dir| {
                if (content_hash) |ch| {
                    has_thumb = cli.format_handler.checkThumbnailExists(c_ctx.io, allocator, ch, thumb_dir);
                    if (!has_thumb) {
                        if (res.thumbnail_data) |thumb_bytes| {
                            has_thumb = cli.format_handler.saveThumbnailBytes(c_ctx.io, allocator, ch, thumb_dir, thumb_bytes) catch false;
                        } else if (c_ctx.has_ffmpeg) {
                            if (c_ctx.ffmpeg_sem) |sem| sem.waitUncancelable(c_ctx.io);
                            defer if (c_ctx.ffmpeg_sem) |sem| sem.post(c_ctx.io);
                            has_thumb = cli.format_handler.generateFfmpegThumbnail(c_ctx.io, allocator, c_ctx.ffmpeg_path, path, ch, thumb_dir, false) catch false;
                        }
                    }

                    // Same sibling re-stat as the video branch / queryHashRecord
                    if (!has_thumb)
                        has_thumb = cli.format_handler.checkThumbnailExists(c_ctx.io, allocator, ch, thumb_dir);
                }
            }
            record = try db.populateJsonFromImage(allocator, &res, path, size, has_thumb);
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

    pub fn processFile(c_ctx: WorkerContext, entry: media_scan.ScanEntry, is_video: bool) !void {
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
            try cli.output_formatter.printMetadataRecord(c_ctx, record, fsize);
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
                    try cli.output_formatter.printMetadataRecord(c_ctx, record, fsize);
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
        try cli.output_formatter.printMetadataRecord(c_ctx, record, fsize);
    }
};

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
