//! Command-line interface for scanning media files and displaying metadata.
//!
//! This file demonstrates:
//! 1. The Zig 0.16.0 `main` entrypoint design using `std.process.Init`.
//! 2. Custom stdout buffering using raw byte arrays.
//! 3. Standard command-line argument processing.
//! 4. Absolute path resolution and heap memory allocation tracking.

const std = @import("std");
const media_scan = @import("media_scan.zig");
const image_meta = @import("image_meta.zig");
const video_meta = @import("video_meta.zig");

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

const JsonOutput = struct {
    path: []const u8,
    size: u64,
    format: []const u8,
    width: ?u32 = null,
    height: ?u32 = null,
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

    // Scan the directory for media files.
    var results = try media_scan.scan(abs_target_dir, io, allocator);
    defer {
        for (results.items) |entry| {
            allocator.free(entry.path);
        }
        results.deinit(allocator);
    }

    if (!json_mode) {
        std.debug.print("Scanning: {s}\n", .{target_dir});
        std.debug.print("Found {d} media file(s)\n\n", .{results.items.len});
    }

    // Step 2: Try parsing metadata.
    for (results.items) |entry| {
        const ext = media_scan.getExtension(entry.path);
        var json_out = JsonOutput{
            .path = entry.path,
            .size = entry.size,
            .format = "unknown",
        };

        const is_video = isVideoExtension(ext);
        if (is_video) {
            if (video_meta.getVideoMetadata(allocator, entry.path, io)) |res| {
                json_out.format = res.format;
                json_out.width = res.width;
                json_out.height = res.height;
            } else |err| {
                std.debug.print("Warning: failed to parse video '{s}': {s}\n", .{ entry.path, @errorName(err) });
            }
        } else {
            // Attempt image metadata extraction.
            if (image_meta.parseFile(entry.path, io)) |res| {
                json_out.format = res.format;
                json_out.width = res.width;
                json_out.height = res.height;
            } else |err| {
                std.debug.print("Warning: failed to parse image '{s}': {s}\n", .{ entry.path, @errorName(err) });
            }
        }

        if (json_mode) {
            try std.json.fmt(json_out, .{}).format(out);
            try out.print("\n", .{});
        } else {
            try out.print("   {s} ({d} bytes)\n", .{ entry.path, entry.size });
            if (std.mem.eql(u8, json_out.format, "unknown")) {
                if (is_video) {
                    try out.print("    Format: unknown/unsupported video\n", .{});
                } else {
                    try out.print("    Format: unknown/unsupported image\n", .{});
                }
            } else {
                if (is_video) {
                    try out.print(
                        "    Format: MP4 (Video)\n" ++
                            "    Dimensions: {d} x {d}\n",
                        .{ json_out.width.?, json_out.height.? },
                    );
                } else {
                    try out.print(
                        "    Format: {s}\n" ++
                            "    Dimensions: {d} x {d}\n",
                        .{ json_out.format, json_out.width.?, json_out.height.? },
                    );
                }
            }
            try out.print("\n", .{});
        }
    }

    try out.flush();
}
