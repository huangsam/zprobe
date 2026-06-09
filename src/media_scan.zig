//! Directory Scanning and Filter Logic.
//!
//! This module showcases:
//! 1. Recursive directory traversal using `std.Io.Dir.walk`.
//! 2. Safe string parsing and allocation-free case conversions.
//! 3. Memory ownership boundaries in Zig (passing allocators explicitly).

const std = @import("std");
const Dir = @import("std").Io.Dir;

/// Represents a media file found during a directory scan.
///
/// ### Memory Lifecycle:
/// The `path` field contains a heap-allocated string containing the absolute path
/// to the file. The caller is responsible for freeing `path` using the same
/// allocator passed to `scan`.
pub const ScanEntry = struct {
    path: []u8,
    is_directory: bool,
    size: u64 = 0,
};

/// Supported image extensions.
pub const imageExtensions = [_][]const u8{
    ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tiff", ".tif", ".webp", ".svg",
};

/// Supported video extensions.
pub const videoExtensions = [_][]const u8{
    ".mp4", ".m4v", ".mov", ".avi", ".mkv", ".webm", ".wmv", ".flv",
};

/// Check whether the given extension identifies a media file.
///
/// This does not allocate any heap memory. It performs case conversion on
/// a stack-allocated buffer (`ext_lower`).
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
///
/// Resolves the base file name from directory slashes and slices the extension,
/// returning an empty slice if no dot exists.
pub fn getExtension(path: []const u8) []const u8 {
    var last_slash: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/') last_slash = i + 1;
    }
    const base = path[last_slash..];
    var last_dot: ?usize = null;
    for (base, 0..) |c, i| {
        if (c == '.') last_dot = i;
    }
    if (last_dot) |dot_idx| {
        return base[dot_idx..];
    }
    return "";
}

/// Recursively walk a directory tree and collect entries whose extensions
/// match known image or video formats.
///
/// ### Memory Allocation & Ownership:
/// - Allocates a `std.ArrayList(ScanEntry)` using the provided `allocator`.
/// - Allocates paths for each successfully matched file.
/// - If a scan fails midway, the function leverages `errdefer` to release all
///   internally allocated resources, preventing leaks.
pub fn scan(root_path: []const u8, io: anytype, allocator: std.mem.Allocator) !std.ArrayList(ScanEntry) {
    var list: std.ArrayList(ScanEntry) = .empty;
    errdefer list.deinit(allocator);

    // Open root directory for iteration.
    const root_dir = try Dir.openDirAbsolute(io, root_path, .{ .iterate = true });
    defer Dir.close(root_dir, io);

    var walker = try Dir.walk(root_dir, allocator);

    defer walker.deinit();

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

        // Join root_path and entry.path to get the full absolute path.
        const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.path });
        errdefer allocator.free(full_path);
        try list.append(allocator, .{
            .path = full_path,
            .is_directory = false,
            .size = fsize,
        });
    }

    return list;
}

test "getExtension: simple filename" {
    const ext = getExtension("photo.jpg");
    try std.testing.expectEqualStrings(".jpg", ext);
}

test "getExtension: nested path" {
    const ext = getExtension("/home/user/images/cat.png");
    try std.testing.expectEqualStrings(".png", ext);
}

test "getExtension: no extension returns empty" {
    const ext = getExtension("README");
    try std.testing.expectEqualStrings("", ext);
}

test "getExtension: multiple dots" {
    const ext = getExtension("archive.tar.gz");
    try std.testing.expectEqualStrings(".gz", ext);
}

test "getExtension: extension only no dot" {
    const ext = getExtension("Makefile");
    try std.testing.expectEqualStrings("", ext);
}

test "isMediaExtension: known image extensions" {
    try std.testing.expect(isMediaExtension(".jpg"));
    try std.testing.expect(isMediaExtension(".png"));
    try std.testing.expect(isMediaExtension(".gif"));
    try std.testing.expect(isMediaExtension(".bmp"));
    try std.testing.expect(isMediaExtension(".webp"));
}

test "isMediaExtension: known video extensions" {
    try std.testing.expect(isMediaExtension(".mp4"));
    try std.testing.expect(isMediaExtension(".mov"));
    try std.testing.expect(isMediaExtension(".avi"));
    try std.testing.expect(isMediaExtension(".mkv"));
}

test "isMediaExtension: case insensitive" {
    try std.testing.expect(isMediaExtension(".JPG"));
    try std.testing.expect(isMediaExtension(".Png"));
    try std.testing.expect(isMediaExtension(".MP4"));
}

test "isMediaExtension: unknown extension returns false" {
    try std.testing.expect(!isMediaExtension(".xyz"));
    try std.testing.expect(!isMediaExtension(".txt"));
    try std.testing.expect(!isMediaExtension(".exe"));
}

test "isMediaExtension: empty string returns false" {
    try std.testing.expect(!isMediaExtension(""));
}
