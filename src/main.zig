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

pub fn computeWorkerCount(cpu_count: usize) usize {
    return @min(@max(cpu_count * 4, 8), 16);
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
};

fn checkFFmpeg(io: std.Io) bool {
    const allocator = std.heap.page_allocator;

    const decoders_res = std.process.run(allocator, io, .{
        .argv = &.{ "ffmpeg", "-decoders" },
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
        .argv = &.{ "ffmpeg", "-encoders" },
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

    return true;
}

fn generateFfmpegThumbnail(io: std.Io, allocator: std.mem.Allocator, original_path: []const u8, thumb_dir: []const u8, is_video: bool) !bool {
    var hash_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(original_path, &hash_bytes, .{});
    const hex_hash = std.fmt.bytesToHex(hash_bytes, .lower);

    const thumb_path = try std.fs.path.join(allocator, &.{ thumb_dir, &hex_hash });
    defer allocator.free(thumb_path);
    const thumb_path_jpg = try std.fmt.allocPrint(allocator, "{s}.jpg", .{thumb_path});
    defer allocator.free(thumb_path_jpg);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{ "ffmpeg", "-y", "-nostdin", "-threads", "1" });
    if (is_video) {
        try argv.appendSlice(allocator, &.{ "-skip_frame", "nokey", "-ss", "00:00:01" });
    }
    try argv.appendSlice(allocator, &.{ "-i", original_path });
    if (is_video) {
        // -vframes 1 captures a single frame; -t 10 is a standard output-side
        // time limit that aborts gracefully if the seek or decode stalls.
        try argv.appendSlice(allocator, &.{ "-vframes", "1", "-t", "10" });
    }
    try argv.appendSlice(allocator, &.{ "-vf", "scale=iw*min(320/iw\\,320/ih):ih*min(320/iw\\,320/ih)", "-f", "image2", thumb_path_jpg });

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn saveThumbnailBytes(io: std.Io, allocator: std.mem.Allocator, original_path: []const u8, thumb_dir: []const u8, bytes: []const u8) !bool {
    var hash_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(original_path, &hash_bytes, .{});
    const hex_hash = std.fmt.bytesToHex(hash_bytes, .lower);

    const thumb_path = try std.fs.path.join(allocator, &.{ thumb_dir, &hex_hash });
    defer allocator.free(thumb_path);
    const thumb_path_jpg = try std.fmt.allocPrint(allocator, "{s}.jpg", .{thumb_path});
    defer allocator.free(thumb_path_jpg);

    const file = std.Io.Dir.createFileAbsolute(io, thumb_path_jpg, .{}) catch return false;
    defer std.Io.File.close(file, io);
    try std.Io.File.writePositionalAll(file, io, bytes, 0);
    return true;
}

fn checkThumbnailExists(io: std.Io, allocator: std.mem.Allocator, original_path: []const u8, thumb_dir: []const u8) bool {
    var hash_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(original_path, &hash_bytes, .{});
    const hex_hash = std.fmt.bytesToHex(hash_bytes, .lower);

    const thumb_path = std.fs.path.join(allocator, &.{ thumb_dir, &hex_hash }) catch return false;
    defer allocator.free(thumb_path);
    const thumb_path_jpg = std.fmt.allocPrint(allocator, "{s}.jpg", .{thumb_path}) catch return false;
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

        var cache_hit = false;
        var json_out: db.DbRecord = undefined;

        if (c_ctx.db) |d| {
            d.lockRead(c_ctx.io);
            const cache_res = d.queryCache(arena_allocator, entry.path, fsize, mtime) catch |err| blk: {
                std.debug.print("Warning: cache query failed: {s}\n", .{@errorName(err)});
                break :blk db.CacheResult{ .hit = false };
            };
            d.unlockRead(c_ctx.io);

            if (cache_res.hit) {
                cache_hit = true;
                json_out = cache_res.json_out;

                if (c_ctx.rebuild_thumbnails and c_ctx.thumb_dir != null) {
                    const has_thumb_file = checkThumbnailExists(c_ctx.io, arena_allocator, entry.path, c_ctx.thumb_dir.?);
                    if (!has_thumb_file) {
                        cache_hit = false;
                    }
                }
            }
        }

        if (!cache_hit) {
            var file_hash: ?[]const u8 = null;
            var hash_hit = false;

            if (hashing.computeFastHash(c_ctx.io, arena_allocator, entry.path)) |hash| {
                file_hash = hash;
                if (c_ctx.db) |d| {
                    d.lockRead(c_ctx.io);
                    const hash_res = d.queryMetadataByHash(arena_allocator, entry.path, hash) catch null;
                    d.unlockRead(c_ctx.io);

                    if (hash_res) |res| {
                        hash_hit = true;
                        json_out = res;
                        json_out.size = fsize; // ensure size is correct

                        d.lockWrite(c_ctx.io);
                        d.insertMedia(&json_out, mtime) catch |err| {
                            std.debug.print("Warning: failed to insert duplicate media path to DB: {s}\n", .{@errorName(err)});
                        };
                        d.unlockWrite(c_ctx.io);
                        cache_hit = true;
                    }
                }
            } else |err| {
                std.debug.print("Warning: failed to compute fast hash for '{s}': {s}\n", .{ entry.path, @errorName(err) });
            }

            if (!hash_hit) {
                var has_thumb = false;
                if (is_video) {
                    var res = video_meta.getVideoMetadata(arena_allocator, entry.path, c_ctx.io) catch |err| {
                        c_ctx.stdout_mutex.lockUncancelable(c_ctx.io);
                        defer c_ctx.stdout_mutex.unlock(c_ctx.io);
                        c_ctx.out.flush() catch {};
                        std.debug.print("Warning: failed to parse video '{s}': {s}\n", .{ entry.path, @errorName(err) });
                        return;
                    };
                    if (c_ctx.thumb_dir) |thumb_dir| {
                        if (c_ctx.has_ffmpeg) {
                            if (c_ctx.ffmpeg_sem) |sem| sem.waitUncancelable(c_ctx.io);
                            defer if (c_ctx.ffmpeg_sem) |sem| sem.post(c_ctx.io);
                            has_thumb = generateFfmpegThumbnail(c_ctx.io, arena_allocator, entry.path, thumb_dir, true) catch false;
                        }
                    }
                    json_out = try populateJsonFromVideo(arena_allocator, &res, entry.path, fsize, has_thumb);
                } else {
                    var res = image_meta.parseFile(arena_allocator, entry.path, c_ctx.io) catch |err| {
                        c_ctx.stdout_mutex.lockUncancelable(c_ctx.io);
                        defer c_ctx.stdout_mutex.unlock(c_ctx.io);
                        c_ctx.out.flush() catch {};
                        std.debug.print("Warning: failed to parse image '{s}': {s}\n", .{ entry.path, @errorName(err) });
                        return;
                    };
                    if (c_ctx.thumb_dir) |thumb_dir| {
                        if (res.thumbnail_data) |thumb_bytes| {
                            has_thumb = saveThumbnailBytes(c_ctx.io, arena_allocator, entry.path, thumb_dir, thumb_bytes) catch false;
                        } else if (c_ctx.has_ffmpeg) {
                            if (c_ctx.ffmpeg_sem) |sem| sem.waitUncancelable(c_ctx.io);
                            defer if (c_ctx.ffmpeg_sem) |sem| sem.post(c_ctx.io);
                            has_thumb = generateFfmpegThumbnail(c_ctx.io, arena_allocator, entry.path, thumb_dir, false) catch false;
                        }
                    }
                    json_out = try populateJsonFromImage(arena_allocator, &res, entry.path, fsize, has_thumb);
                }

                if (file_hash) |fh| {
                    json_out.file_hash = try arena_allocator.dupe(u8, fh);
                }

                if (c_ctx.db) |d| {
                    d.lockWrite(c_ctx.io);
                    d.insertMedia(&json_out, mtime) catch |err| {
                        std.debug.print("Warning: failed to insert media to DB: {s}\n", .{@errorName(err)});
                    };
                    d.unlockWrite(c_ctx.io);
                }
            }
        }

        c_ctx.stdout_mutex.lockUncancelable(c_ctx.io);
        defer c_ctx.stdout_mutex.unlock(c_ctx.io);

        _ = c_ctx.success_count.fetchAdd(1, .monotonic);

        const interface = &c_ctx.out.interface;

        if (c_ctx.json_mode) {
            try std.json.fmt(json_out, .{}).format(interface);
            try interface.print("\n", .{});
        } else {
            try interface.print("   {s} ({d} bytes)\n", .{ entry.path, fsize });
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
};

fn printHelp(out: anytype, exe_name: []const u8) !void {
    try out.print(
        \\zprobe - Media header scanning and metadata indexing tool
        \\
        \\Usage:
        \\  {s} [options] <directory>...
        \\
        \\Options:
        \\  -h, --help           Show this help message and exit
        \\  --json               Output metadata in JSON lines format
        \\  --db <database>      Path to SQLite database for metadata caching and indexing
        \\  -j, --concurrency <n> Number of concurrent worker threads (default: CPU-based dynamic clamp 8-16)
        \\  --no-thumbnails      Bypass generating and saving thumbnails (useful on slow NAS / 1GB RAM)
        \\  --rebuild-thumbnails Re-generate missing thumbnails during scanning
        \\  --prune              Prune stale cache entries from DB for paths inside scanned directories but no longer present on disk
        \\
        \\Supported Formats:
        \\  Images: JPEG, PNG, GIF, BMP, WebP, TIFF, AVIF, ICO, JXL
        \\  Videos: MP4, MOV, WebM, MKV
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
    var prune_mode = false;

    var arg_idx: usize = 1;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--no-thumbnails")) {
            no_thumbnails = true;
        } else if (std.mem.eql(u8, arg, "--rebuild-thumbnails")) {
            rebuild_thumbnails = true;
        } else if (std.mem.eql(u8, arg, "--prune")) {
            prune_mode = true;
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

        var dir_list = try media_scan.scan(abs_dir, io, allocator);
        errdefer {
            for (dir_list.items) |entry| {
                allocator.free(entry.path);
            }
            dir_list.deinit(allocator);
        }

        try all_entries.appendSlice(allocator, dir_list.items);
        dir_list.deinit(allocator);
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
    const num_workers = if (concurrency_override) |override| override else computeWorkerCount(cpu_count);

    const threads = try allocator.alloc(std.Thread, num_workers);
    defer allocator.free(threads);

    const has_ffmpeg = checkFFmpeg(io);
    const ffmpeg_concurrency = @min(num_workers, @min(@max(cpu_count / 2, 1), 4));
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

    // Run pruning pass if requested
    if (prune_mode and db_ptr != null) {
        const d = db_ptr.?;
        var active_paths = std.StringHashMap(void).init(allocator);
        defer active_paths.deinit();
        for (all_entries.items) |entry| {
            try active_paths.put(entry.path, {});
        }

        const pruned_count = try d.pruneStalePaths(target_dirs.items, &active_paths);
        if (pruned_count > 0 and !json_mode) {
            std.debug.print("Pruned {d} stale cache entries\n", .{pruned_count});
        }
    }

    // Commit transaction
    if (db_ptr) |d| {
        d.commitTransaction();
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
    var list = try media_scan.scan(temp_ctx.abs_path, io, allocator);
    defer {
        for (list.items) |entry| {
            allocator.free(entry.path);
        }
        list.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 50), list.items.len);

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
        .entries = list.items,
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

test "computeWorkerCount boundaries" {
    try std.testing.expectEqual(@as(usize, 8), computeWorkerCount(1));
    try std.testing.expectEqual(@as(usize, 8), computeWorkerCount(2));
    try std.testing.expectEqual(@as(usize, 12), computeWorkerCount(3));
    try std.testing.expectEqual(@as(usize, 16), computeWorkerCount(4));
    try std.testing.expectEqual(@as(usize, 16), computeWorkerCount(8));
    try std.testing.expectEqual(@as(usize, 16), computeWorkerCount(16));
}

test "isVideoExtension boundaries" {
    try std.testing.expect(isVideoExtension(".mp4"));
    try std.testing.expect(isVideoExtension(".mkv"));
    try std.testing.expect(!isVideoExtension(".png"));
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
    var list = try media_scan.scan(temp_ctx.abs_path, io, allocator);
    defer {
        for (list.items) |entry| {
            allocator.free(entry.path);
        }
        list.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), list.items.len);

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
        .entries = list.items,
        .file_index = &file_index,
        .stdout_mutex = &stdout_mutex,
        .success_count = &success_count,
        .db = &database,
        .thumb_dir = null,
        .has_ffmpeg = false,
    };

    // First Run (should parse & cache)
    worker.processFile(worker_ctx, list.items[0], false) catch |err| {
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
    try database.insertMedia(&updated_record, new_mtime);

    // Reset loop index & success counter
    file_index.store(0, .monotonic);
    success_count.store(0, .monotonic);

    // Second Run (should cache hit and NOT fail on the corrupted PNG!)
    worker.processFile(worker_ctx, list.items[0], false) catch |err| {
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

    // 1. Verify checkThumbnailExists returns false since no thumbnail exists yet
    try std.testing.expect(!checkThumbnailExists(io, allocator, full_image_path, full_thumb_path));

    // Create a mock thumbnail file manually
    var hash_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(full_image_path, &hash_bytes, .{});
    const hex_hash = std.fmt.bytesToHex(hash_bytes, .lower);
    const mock_thumb_filename = try std.fmt.allocPrint(allocator, "{s}.jpg", .{hex_hash});
    defer allocator.free(mock_thumb_filename);

    const mock_thumb_file = try std.Io.Dir.createFile(temp_dir, io, mock_thumb_filename, .{});
    try std.Io.File.writePositionalAll(mock_thumb_file, io, "MOCK_THUMB", 0);
    std.Io.File.close(mock_thumb_file, io);

    // 2. Verify checkThumbnailExists now returns true
    try std.testing.expect(checkThumbnailExists(io, allocator, full_image_path, temp_ctx.abs_path));
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

    try database.insertMedia(&rec1, 10);
    try database.insertMedia(&rec2, 20);

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
    const pruned_count = try database.pruneStalePaths(target_dirs.items, &active_paths);
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
