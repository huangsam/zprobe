const std = @import("std");

/// Search standard paths or invoke command to verify FFmpeg executable and decoders/encoders are available.
pub fn checkFFmpeg(io: std.Io, ffmpeg_path: []const u8) bool {
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
