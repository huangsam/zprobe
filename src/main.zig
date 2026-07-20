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
const cli = root.cli;
const test_utils = @import("core/test_utils.zig");
const db = root.db;
const hashing = root.hashing;

/// Generation policy for a content-keyed artifact type. `--thumbnails` and
/// `--animations` share this grammar; only their defaults and on-disk roots differ.
/// Helper to initialize a buffered file writer targeting stdout.
///
/// In Zig 0.16.0, `std.Io.File.Writer` provides buffered output streams
/// wrapping the system output resource.
fn file_writer(io: anytype, buffer: []u8) std.Io.File.Writer {
    return std.Io.File.Writer.init(.stdout(), io, buffer);
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

    // Use cli module to parse arguments
    var cli_opts: cli.CliOptions = undefined;
    if (cli.CliOptions.parse(allocator, args, out)) |opts| {
        cli_opts = opts;
    } else |err| {
        if (err == error.InvalidArgument) {
            try out.flush();
            std.process.exit(1);
        }
        return err;
    }

    const target_db = cli_opts.target_db;
    const show_help = cli_opts.show_help;
    const concurrency_override = cli_opts.concurrency_override;
    const thumbnails = cli_opts.thumbnails;
    const animations = cli_opts.animations;
    const prune_mode = cli_opts.prune_mode;
    const ffmpeg_path_override = cli_opts.ffmpeg_path_override;
    const target_dirs = &cli_opts.target_dirs;

    if (show_help) {
        try cli.printHelp(out, args[0]);
        try out.flush();
        cli_opts.deinit(allocator);
        return;
    }

    if (target_dirs.items.len == 0) {
        try out.print("Error: No directories specified\n", .{});
        try out.flush();
        cli_opts.deinit(allocator);
        return;
    }

    const env_ffmpeg = init.environ_map.get("ZPROBE_FFMPEG_PATH");
    const ffmpeg_path = if (ffmpeg_path_override) |path| path else (if (env_ffmpeg) |path| path else "ffmpeg");

    // FFmpeg is only needed when at least one artifact type is being generated.
    const want_ffmpeg = thumbnails.generates() or animations.generates();
    const has_ffmpeg = if (want_ffmpeg) cli.ffmpeg.checkFFmpeg(io, ffmpeg_path) else false;
    if (want_ffmpeg) {
        if (has_ffmpeg) {
            std.debug.print("FFmpeg detected and validated: {s}\n", .{ffmpeg_path});
        } else {
            // Name only the artifacts this run actually depends on ffmpeg for.
            const skipped = if (thumbnails.generates() and animations.generates())
                "Video/fallback image thumbnails and animated previews will be skipped"
            else if (thumbnails.generates())
                "Video and fallback image thumbnails will be skipped"
            else
                "Animated previews will be skipped";
            std.debug.print("Warning: FFmpeg not found or invalid at '{s}'. {s}.\n", .{ ffmpeg_path, skipped });
        }
    }

    // Initialize Database if path is provided
    var database: db.Db = undefined;
    var db_ptr: ?*db.Db = null;
    var thumb_dir_path: ?[]const u8 = null;
    var anim_dir_path: ?[]const u8 = null;
    defer if (thumb_dir_path) |p| allocator.free(p);
    defer if (anim_dir_path) |p| allocator.free(p);

    if (target_db.len > 0) {
        database = try db.Db.init(allocator, target_db);
        db_ptr = &database;
        database.beginTransaction();

        // Each artifact type gets its own root next to the DB; create only what
        // the corresponding mode generates so the two folders stay independent.
        if (thumbnails.generates() or animations.generates()) {
            // Resolve absolute DB directory to anchor the artifact roots.
            const cwd = std.Io.Dir.cwd();
            const dir = std.fs.path.dirname(target_db) orelse ".";
            const abs_dir = cwd.realPathFileAlloc(io, dir, allocator) catch null;
            defer if (abs_dir) |path| allocator.free(path);
            const resolved_dir = if (abs_dir) |path| path else dir;
            const abs_db = try std.fs.path.join(allocator, &.{ resolved_dir, std.fs.path.basename(target_db) });
            defer allocator.free(abs_db);

            const db_dir = std.fs.path.dirname(abs_db) orelse ".";
            if (thumbnails.generates()) {
                thumb_dir_path = try std.fs.path.join(allocator, &.{ db_dir, ".zprobe_thumbnails" });
                std.Io.Dir.createDirPath(cwd, io, thumb_dir_path.?) catch |err| {
                    if (err != error.PathAlreadyExists and err != error.DirExists) {
                        std.debug.print("Warning: failed to create thumbnail directory: {s}\n", .{@errorName(err)});
                    }
                };
            }
            if (animations.generates()) {
                anim_dir_path = try std.fs.path.join(allocator, &.{ db_dir, ".zprobe_animations" });
                std.Io.Dir.createDirPath(cwd, io, anim_dir_path.?) catch |err| {
                    if (err != error.PathAlreadyExists and err != error.DirExists) {
                        std.debug.print("Warning: failed to create animation directory: {s}\n", .{@errorName(err)});
                    }
                };
            }
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

    var profile_metrics = cli.ProfileMetrics.init(cli_opts.profile_mode);
    var total_timer = cli.MonotonicTimer.start(io);

    const cwd = std.Io.Dir.cwd();
    for (target_dirs.items) |dir_path| {
        const abs_dir = cwd.realPathFileAlloc(io, dir_path, allocator) catch |err| {
            try out.print("Error: Failed to resolve path '{s}': {s}\n", .{ dir_path, @errorName(err) });
            try out.flush();
            return;
        };
        defer allocator.free(abs_dir);

        std.debug.print("Scanning: {s}\n", .{dir_path});

        var crawl_timer = if (cli_opts.profile_mode) cli.MonotonicTimer.start(io) else undefined;
        var scan_res = try media_scan.scan(abs_dir, io, allocator);
        if (cli_opts.profile_mode) {
            profile_metrics.record(&profile_metrics.dir_crawl_ns, crawl_timer.read());
        }
        errdefer {
            for (scan_res.entries.items) |entry| {
                allocator.free(entry.path);
            }
            scan_res.entries.deinit(allocator);
        }

        if (scan_res.degraded) {
            std.debug.print("Warning: Scan of '{s}' was degraded due to errors; pruning will be skipped for this directory.\n", .{dir_path});
        }

        if (!scan_res.degraded and scan_res.entries.items.len > 0) {
            const dup = try allocator.dupe(u8, abs_dir);
            try prunable_dirs.append(allocator, dup);
        }

        try all_entries.appendSlice(allocator, scan_res.entries.items);
        scan_res.entries.deinit(allocator);
    }

    std.debug.print("\n", .{});

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

    const worker_ctx = cli.worker_pool.WorkerContext{
        .allocator = allocator,
        .io = io,
        .out = &f_writer,
        .entries = all_entries.items,
        .file_index = &file_index,
        .stdout_mutex = &stdout_mutex,
        .success_count = &success_count,
        .db = db_ptr,
        .thumbnails = thumbnails,
        .animations = animations,
        .thumb_dir = thumb_dir_path,
        .anim_dir = anim_dir_path,
        .has_ffmpeg = has_ffmpeg,
        .ffmpeg_sem = &ffmpeg_sem,
        .ffmpeg_path = ffmpeg_path,
        .profile_metrics = if (cli_opts.profile_mode) &profile_metrics else null,
    };

    var spawned_count: usize = 0;
    defer {
        for (threads[0..spawned_count]) |t| {
            t.join();
        }
    }

    for (0..num_workers) |k| {
        threads[k] = try std.Thread.spawn(.{}, cli.worker_pool.worker.workerMain, .{worker_ctx});
        spawned_count += 1;
    }

    for (threads[0..spawned_count]) |t| {
        t.join();
    }
    spawned_count = 0;

    var prune_commit_timer = if (cli_opts.profile_mode) cli.MonotonicTimer.start(io) else undefined;

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
        if (pruned_count > 0) {
            std.debug.print("Pruned {d} stale cache entries\n", .{pruned_count});
        }
    }

    // Commit transaction
    if (db_ptr) |d| {
        d.commitTransaction(io);
    }

    if (cli_opts.profile_mode) {
        profile_metrics.record(&profile_metrics.prune_commit_ns, prune_commit_timer.read());
    }

    try out.flush();

    // Defer CLI options cleanup - must happen after all target_dirs usage
    defer cli_opts.deinit(allocator);

    const total_ns = total_timer.read();
    if (cli_opts.profile_mode) {
        var dur_crawl_buf: [32]u8 = undefined;
        var dur_worker_buf: [32]u8 = undefined;
        var dur_cache_buf: [32]u8 = undefined;
        var dur_hash_buf: [32]u8 = undefined;
        var dur_parse_buf: [32]u8 = undefined;
        var dur_ffmpeg_buf: [32]u8 = undefined;
        var dur_prune_buf: [32]u8 = undefined;

        const dur_crawl = formatDurationBuf(&dur_crawl_buf, profile_metrics.dir_crawl_ns.load(.monotonic)) catch "0ms";
        const dur_worker = formatDurationBuf(&dur_worker_buf, profile_metrics.worker_processing_ns.load(.monotonic)) catch "0ms";
        const dur_cache = formatDurationBuf(&dur_cache_buf, profile_metrics.cache_queries_ns.load(.monotonic)) catch "0ms";
        const dur_hash = formatDurationBuf(&dur_hash_buf, profile_metrics.file_hashing_ns.load(.monotonic)) catch "0ms";
        const dur_parse = formatDurationBuf(&dur_parse_buf, profile_metrics.header_parsing_ns.load(.monotonic)) catch "0ms";
        const dur_ffmpeg = formatDurationBuf(&dur_ffmpeg_buf, profile_metrics.ffmpeg_spawns_ns.load(.monotonic)) catch "0ms";
        const dur_prune = formatDurationBuf(&dur_prune_buf, profile_metrics.prune_commit_ns.load(.monotonic)) catch "0ms";

        std.debug.print("Found {d} media file(s) in {f}\n", .{ all_entries.items.len, cli.DurationFormatter{ .ns = total_ns } });
        std.debug.print("  ├── Directory crawl:   {s}\n", .{dur_crawl});
        std.debug.print("  ├── Worker processing: {s} (cumulative)\n", .{dur_worker});
        std.debug.print("  │    ├── Cache queries:     {s}\n", .{dur_cache});
        std.debug.print("  │    ├── File hashing:     {s}\n", .{dur_hash});
        std.debug.print("  │    ├── Header parsing:    {s}\n", .{dur_parse});
        std.debug.print("  │    └── FFmpeg spawns:   {s}\n", .{dur_ffmpeg});
        std.debug.print("  └── Pruning & commits:  {s}\n", .{dur_prune});
    } else {
        std.debug.print("Found {d} media file(s) in {f}\n", .{ all_entries.items.len, cli.DurationFormatter{ .ns = total_ns } });
    }
}

fn formatDurationBuf(buf: []u8, ns: u64) ![]const u8 {
    const ns_f = @as(f64, @floatFromInt(ns));
    if (ns >= 1_000_000_000) {
        return try std.fmt.bufPrint(buf, "{d:.2}s", .{ns_f / 1_000_000_000.0});
    } else if (ns >= 1_000_000) {
        return try std.fmt.bufPrint(buf, "{d:.2}ms", .{ns_f / 1_000_000.0});
    } else if (ns >= 1_000) {
        return try std.fmt.bufPrint(buf, "{d:.2}us", .{ns_f / 1_000.0});
    } else {
        return try std.fmt.bufPrint(buf, "{d}ns", .{ns});
    }
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

    // Run with -j 1 and --thumbnails=off (animations default off). Neither artifact
    // root should be created.
    const run_res = try std.process.run(allocator, io, .{
        .argv = &.{ abs_bin_path, "-j", "1", "--thumbnails=off", "--db", full_db_path, temp_ctx.abs_path },
    });
    defer {
        allocator.free(run_res.stdout);
        allocator.free(run_res.stderr);
    }

    try std.testing.expectEqual(@as(u32, 0), switch (run_res.term) {
        .exited => |code| code,
        else => 99,
    });

    // Verify neither artifact directory was created
    const thumb_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, ".zprobe_thumbnails" });
    defer allocator.free(thumb_path);
    const thumb_exists = if (std.Io.Dir.openDirAbsolute(io, thumb_path, .{})) |d| blk: {
        std.Io.Dir.close(d, io);
        break :blk true;
    } else |_| false;
    try std.testing.expect(!thumb_exists);
    const anim_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, ".zprobe_animations" });
    defer allocator.free(anim_path);
    const anim_exists = if (std.Io.Dir.openDirAbsolute(io, anim_path, .{})) |d| blk: {
        std.Io.Dir.close(d, io);
        break :blk true;
    } else |_| false;
    try std.testing.expect(!anim_exists);
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
