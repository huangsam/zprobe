//! Recursive directory scanner yielding file entries for metadata extraction.
const std = @import("std");
const Dir = @import("std").Io.Dir;

/// A file discovered during scanning.
pub const ScanEntry = struct {
    path: []u8,
    is_directory: bool,
    size: u64 = 0,
};

/// Extensions recognized as image files.
pub const imageExtensions = [_][]const u8{
    ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tiff", ".tif", ".webp", ".svg",
};

/// Extensions recognized as video files.
pub const videoExtensions = [_][]const u8{
    ".mp4", ".m4v", ".mov", ".avi", ".mkv", ".webm", ".wmv", ".flv",
};

/// Check whether the given extension identifies a media file.
pub fn isMediaExtension(ext: []const u8) bool {
    var ext_lower: [16]u8 = undefined;
    const slice = std.ascii.lowerString(&ext_lower, ext);

    for (imageExtensions) |ie| {
        if (std.mem.eql(u8, slice, ie)) return true;
    }
    for (videoExtensions) |ve| {
        if (std.mem.eql(u8, slice, ve)) return true;
    }
    return false;
}

/// Extract the file extension from a path (e.g. "photo.jpg" -> ".jpg").
pub fn getExtension(path: []const u8) []const u8 {
    var last_slash: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/') last_slash = i + 1;
    }
    const base = path[last_slash..];
    for (base, 0..) |c, i| {
        if (c == '.') return base[i..];
    }
    return "";
}

/// Recursively walk a directory tree and collect entries whose extensions
/// match known image or video formats. Returns an ArrayList of ScanEntry.
pub fn scan(root_path: []const u8, io: anytype, allocator: std.mem.Allocator) !std.ArrayList(ScanEntry) {
    var list: std.ArrayList(ScanEntry) = .empty;
    defer list.deinit(allocator);

    // Open root directory for iteration.
    const root_dir = try Dir.openDirAbsolute(io, root_path, .{ .iterate = true });
    defer Dir.close(root_dir, io);

    var walker = try Dir.walk(root_dir, allocator);
    errdefer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        // Check extension.
        const ext = getExtension(entry.basename);
        if (ext.len == 0 or !isMediaExtension(ext)) continue;

        // Open file, read size, close.
        var fsize: u64 = 0;
        const file = try Dir.openFile(entry.dir, io, entry.basename, .{
            .mode = .read_only,
        });
        defer std.Io.File.close(file, io);

        fsize = try std.Io.File.length(file, io);

        // Duplicate path so it survives next() calls.
        const duped = try allocator.dupe(u8, entry.basename);
        errdefer allocator.free(duped);
        try list.append(allocator, .{
            .path = duped,
            .is_directory = false,
            .size = fsize,
        });
    }

    return list;
}
