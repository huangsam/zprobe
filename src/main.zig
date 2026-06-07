const std = @import("std");
const media_scan = @import("media_scan.zig");
const image_meta = @import("image_meta.zig");
const video_meta = @import("video_meta.zig");

/// Print usage to stderr via Io writer.
fn printUsage(io: anytype, prog_name: []const u8) !void {
    const fmt = "Usage: {s} <directory>\n\n" ++
        "Scans the given directory recursively for image and video files,\n" ++
        "extracting dimensions, format, and file size from headers.\n";
    var buffer: [512]u8 = undefined;
    var f_writer = file_writer(io, &buffer);
    const writer = &f_writer.interface;

    try writer.print(fmt, .{prog_name});
}

/// Helper to create a writer for stdout.
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Create a stdout writer.
    var io_buf: [4096]u8 = undefined;
    var f_writer = file_writer(io, &io_buf);
    const out = &f_writer.interface;

    // Get command-line args.
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        try out.print("Usage: {s} <directory>\n", .{args[0]});
        try out.flush();
        return;
    }

    const target_dir = args[1];

    // Scan the directory for media files.
    var results = try media_scan.scan(target_dir, io, allocator);
    defer {
        for (results.items) |entry| {
            allocator.free(entry.path);
        }
        results.deinit(allocator);
    }

    std.debug.print("Scanning: {s}\n", .{target_dir});
    std.debug.print("Found {d} media file(s)\n\n", .{results.items.len});

    // Step 2: Try parsing metadata.
    for (results.items) |entry| {
        try out.print("   {s} ({d} bytes)\n", .{ entry.path, entry.size });

        const ext = media_scan.getExtension(entry.path);
        if (isVideoExtension(ext)) {
            if (video_meta.getVideoMetadata(allocator, entry.path, io)) |res| {
                if (res.video_meta) |vm| {
                    try out.print(
                        "    Format: MP4 (Video)\n" ++
                            "    Dimensions: {d} x {d}\n",
                        .{ vm.width, vm.height },
                    );
                } else {
                    try out.print("    Format: unknown/unsupported video\n", .{});
                }
            } else |_| {
                try out.print("    Format: unknown/unsupported video\n", .{});
            }
        } else {
            // Attempt image metadata extraction.
            if (image_meta.parseFile(entry.path, io)) |dims| {
                try out.print(
                    "    Format: JPEG/PNG/GIF\n" ++
                        "    Dimensions: {d} x {d}\n",
                    .{ dims.width, dims.height },
                );
            } else |_| {
                try out.print("    Format: unknown/unsupported image\n", .{});
            }
        }
        std.debug.print("\n", .{});
    }

    try out.flush();
}
