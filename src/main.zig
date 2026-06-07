//! CLI entry point: scan a directory for media files and print metadata.
const std = @import("std");
const media_scan = @import("media_scan.zig");
const image_meta = @import("image_meta.zig");

/// Print usage to stderr via Io writer.
fn printUsage(io: anytype, prog_name: []const u8) void {
    const fmt = "Usage: {s} <directory>\n\n" ++
        "Scans the given directory recursively for image and video files,\n" ++
        "extracting dimensions, format, and file size from headers.\n";
    var buffer: [512]u8 = undefined;
    const writer = &file_writer(io, &buffer).interface;

    try writer.print(fmt, .{prog_name});
}

/// Helper to create a writer for stdout.
fn file_writer(io: anytype, buffer: []u8) std.Io.File.Writer {
    return std.Io.File.Writer.init(.stdout(), io, buffer);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Create a stdout writer.
    var io_buf: [4096]u8 = undefined;
    const out = &file_writer(io, &io_buf).interface;

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
    defer results.deinit(allocator);

    std.debug.print("Scanning: {s}\n", .{target_dir});
    std.debug.print("Found {d} media file(s)\n\n", .{results.items.len});

    // Step 2: Try parsing metadata.
    for (results.items) |entry| {
        try out.print("   {s} ({d} bytes)\n", .{ entry.path, entry.size });

        // Attempt image metadata extraction.
        switch (image_meta.parseFile(entry.path, io)) {
            .ok => |dims| {
                try out.print(
                    "\n    Format: JPEG/PNG/GIF\n" ++
                        "    Dimensions: {d} x {d}\n",
                    .{ dims.width, dims.height },
                );
            },
            else => {
                try out.print("    Format: unknown/unsupported\n", .{});
            },
        }
        std.debug.print("\n", .{});
    }

    try out.flush();
}
