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

/// Helper to initialize a buffered file writer targeting stdout.
///
/// In Zig 0.16.0, `std.Io.File.Writer` provides buffered output streams
/// wrapping the system output resource.
fn file_writer(io: anytype, buffer: []u8) std.Io.File.Writer {
    return std.Io.File.Writer.init(.stdout(), io, buffer);
}

fn isVideoExtension(ext: []const u8) bool {
    var ext_lower: [16]u8 = undefined;
    const slice = std.ascii.lowerString(&ext_lower, ext);
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

const JsonOutput = struct {
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

    /// Free heap-allocated strings stored within JsonOutput.
    pub fn deinit(self: *const JsonOutput, allocator: std.mem.Allocator) void {
        if (self.create_time) |s| allocator.free(s);
        if (self.camera_make) |s| allocator.free(s);
        if (self.camera_model) |s| allocator.free(s);
    }
};

/// Helper to convert ImageMetadata to JsonOutput, allocating strings in the process.
fn populateJsonFromImage(
    allocator: std.mem.Allocator,
    meta: *const image_meta.ImageMetadata,
    path: []const u8,
    size: u64,
) !JsonOutput {
    var json_out = JsonOutput{
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

/// Helper to convert VideoInfo to JsonOutput.
fn populateJsonFromVideo(
    allocator: std.mem.Allocator,
    meta: *const video_meta.VideoInfo,
    path: []const u8,
    size: u64,
) !JsonOutput {
    var json_out = JsonOutput{
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
};

const worker = struct {
    fn workerMain(c: WorkerContext) void {
        while (true) {
            const idx = c.file_index.fetchAdd(1, .monotonic);
            if (idx >= c.entries.len) break;

            const entry = c.entries[idx];
            const ext = media_scan.getExtension(entry.path);
            const is_video = isVideoExtension(ext);

            processFile(c, entry, is_video) catch {};
        }
    }

    fn processFile(c: WorkerContext, entry: media_scan.ScanEntry, is_video: bool) !void {
        const file = std.Io.Dir.openFileAbsolute(c.io, entry.path, .{ .mode = .read_only }) catch |err| {
            c.stdout_mutex.lockUncancelable(c.io);
            defer c.stdout_mutex.unlock(c.io);
            c.out.flush() catch {};
            std.debug.print("Warning: failed to open '{s}': {s}\n", .{ entry.path, @errorName(err) });
            return;
        };
        defer std.Io.File.close(file, c.io);

        const fsize = std.Io.File.length(file, c.io) catch |err| {
            c.stdout_mutex.lockUncancelable(c.io);
            defer c.stdout_mutex.unlock(c.io);
            c.out.flush() catch {};
            std.debug.print("Warning: failed to get size of '{s}': {s}\n", .{ entry.path, @errorName(err) });
            return;
        };

        var arena = std.heap.ArenaAllocator.init(c.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        const json_out = blk: {
            if (is_video) {
                var res = video_meta.getVideoMetadata(arena_allocator, entry.path, c.io) catch |err| {
                    c.stdout_mutex.lockUncancelable(c.io);
                    defer c.stdout_mutex.unlock(c.io);
                    c.out.flush() catch {};
                    std.debug.print("Warning: failed to parse video '{s}': {s}\n", .{ entry.path, @errorName(err) });
                    return;
                };
                break :blk try populateJsonFromVideo(arena_allocator, &res, entry.path, fsize);
            } else {
                var res = image_meta.parseFile(arena_allocator, entry.path, c.io) catch |err| {
                    c.stdout_mutex.lockUncancelable(c.io);
                    defer c.stdout_mutex.unlock(c.io);
                    c.out.flush() catch {};
                    std.debug.print("Warning: failed to parse image '{s}': {s}\n", .{ entry.path, @errorName(err) });
                    return;
                };
                break :blk try populateJsonFromImage(arena_allocator, &res, entry.path, fsize);
            }
        };

        c.stdout_mutex.lockUncancelable(c.io);
        defer c.stdout_mutex.unlock(c.io);

        _ = c.success_count.fetchAdd(1, .monotonic);

        const interface = &c.out.interface;

        if (c.json_mode) {
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
    var target_dir: []const u8 = "";

    if (args.len < 2) {
        try out.print("Usage: {s} [--json] <directory>\n", .{args[0]});
        try out.flush();
        return;
    }

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else {
            target_dir = arg;
        }
    }

    if (target_dir.len == 0) {
        try out.print("Error: No directory specified\n", .{});
        try out.flush();
        return;
    }

    // Resolve target_dir to an absolute path.
    const cwd = std.Io.Dir.cwd();
    const abs_target_dir = try cwd.realPathFileAlloc(io, target_dir, allocator);
    defer allocator.free(abs_target_dir);

    if (!json_mode) {
        std.debug.print("Scanning: {s}\n\n", .{target_dir});
    }

    var list = try media_scan.scan(abs_target_dir, io, allocator);
    defer {
        for (list.items) |entry| {
            allocator.free(entry.path);
        }
        list.deinit(allocator);
    }

    var file_index = std.atomic.Value(usize).init(0);
    var stdout_mutex = std.Io.Mutex.init;
    var success_count = std.atomic.Value(usize).init(0);

    const cpu_count = std.Thread.getCpuCount() catch 4;
    const num_workers = computeWorkerCount(cpu_count);

    const threads = try allocator.alloc(std.Thread, num_workers);
    defer allocator.free(threads);

    const worker_ctx = WorkerContext{
        .allocator = allocator,
        .io = io,
        .out = &f_writer,
        .json_mode = json_mode,
        .entries = list.items,
        .file_index = &file_index,
        .stdout_mutex = &stdout_mutex,
        .success_count = &success_count,
    };

    var spawned_count: usize = 0;
    defer {
        for (threads[0..spawned_count]) |t| {
            t.join();
        }
    }

    for (0..num_workers) |i| {
        threads[i] = try std.Thread.spawn(.{}, worker.workerMain, .{worker_ctx});
        spawned_count += 1;
    }

    for (threads[0..spawned_count]) |t| {
        t.join();
    }
    spawned_count = 0;

    try out.flush();

    if (!json_mode) {
        std.debug.print("Found {d} media file(s)\n", .{list.items.len});
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
