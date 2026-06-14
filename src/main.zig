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

/// Print usage instructions to the given Io writer.
///
/// Under the hood, this uses a custom buffered writer `file_writer` to
/// optimize system write calls.
fn printUsage(io: anytype, prog_name: []const u8) !void {
    const fmt = "Usage: {s} <directory>\n\n" ++
        "Scans the given directory recursively for image and video files,\n" ++
        "extracting dimensions, format, and file size from headers.\n";
    var buffer: [512]u8 = undefined;
    var f_writer = file_writer(io, &buffer);
    const writer = &f_writer.interface;

    try writer.print(fmt, .{prog_name});
}

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
    pub fn deinit(self: *JsonOutput, allocator: std.mem.Allocator) void {
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

    var ctx = struct {
        allocator: std.mem.Allocator,
        io: @TypeOf(io),
        out: @TypeOf(out),
        json_mode: bool,
        count: usize = 0,
    }{
        .allocator = allocator,
        .io = io,
        .out = out,
        .json_mode = json_mode,
    };

    const processEntry = struct {
        fn call(c: *@TypeOf(ctx), entry: media_scan.ScanEntry) !void {
            c.count += 1;
            const ext = media_scan.getExtension(entry.path);
            const is_video = isVideoExtension(ext);

            var json_out: JsonOutput = undefined;

            if (is_video) {
                var res = video_meta.getVideoMetadata(c.allocator, entry.path, c.io) catch |err| {
                    std.debug.print("Warning: failed to parse video '{s}': {s}\n", .{ entry.path, @errorName(err) });
                    return;
                };
                defer res.deinit(c.allocator);

                json_out = try populateJsonFromVideo(c.allocator, &res, entry.path, entry.size);
            } else {
                // Attempt image metadata extraction.
                var res = image_meta.parseFile(c.allocator, entry.path, c.io) catch |err| {
                    std.debug.print("Warning: failed to parse image '{s}': {s}\n", .{ entry.path, @errorName(err) });
                    return;
                };
                defer res.deinit(c.allocator);

                json_out = try populateJsonFromImage(c.allocator, &res, entry.path, entry.size);
            }
            defer json_out.deinit(c.allocator);

            if (c.json_mode) {
                try std.json.fmt(json_out, .{}).format(c.out);
                try c.out.print("\n", .{});
            } else {
                try c.out.print("   {s} ({d} bytes)\n", .{ entry.path, entry.size });
                if (std.mem.eql(u8, json_out.format, "unknown")) {
                    if (is_video) {
                        try c.out.print("    Format: unknown/unsupported video\n", .{});
                    } else {
                        try c.out.print("    Format: unknown/unsupported image\n", .{});
                    }
                } else {
                    try c.out.print("    Format: {s}\n", .{json_out.format});
                    try c.out.print("    Dimensions: {d} x {d}\n", .{ json_out.width.?, json_out.height.? });
                    if (json_out.orientation) |orient| {
                        try c.out.print("    Orientation: {s}\n", .{formatOrientation(orient)});
                    }
                    if (json_out.create_time) |ct| {
                        try c.out.print("    Captured: {s}\n", .{ct});
                    }
                    if (json_out.camera_make) |make| {
                        try c.out.print("    Camera Make: {s}\n", .{make});
                    }
                    if (json_out.camera_model) |model| {
                        try c.out.print("    Camera Model: {s}\n", .{model});
                    }
                    if (json_out.gps_latitude) |lat| {
                        const lat_ref: u8 = if (lat >= 0) 'N' else 'S';
                        const lon = json_out.gps_longitude.?;
                        const lon_ref: u8 = if (lon >= 0) 'E' else 'W';
                        try c.out.print("    GPS: {d:.4}° {c}, {d:.4}° {c}\n", .{
                            @abs(lat), lat_ref, @abs(lon), lon_ref,
                        });
                    }
                    if (json_out.duration_sec) |dur| {
                        try c.out.print("    Duration: {d:.2} sec\n", .{dur});
                    }
                }
                try c.out.print("\n", .{});
            }
        }
    };

    try media_scan.scanAndProcess(abs_target_dir, io, allocator, &ctx, processEntry.call);

    try out.flush();

    if (!json_mode) {
        std.debug.print("Found {d} media file(s)\n", .{ctx.count});
    }
}
