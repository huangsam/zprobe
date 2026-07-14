const std = @import("std");

/// Compute a fast content signature of a file.
/// Fast Hash = Hash(File Size || First 100KB || Last 100KB)
/// For small files (< 2MB): Hash the entire file sequentially in a single pass.
/// For large files (>= 2MB): Read and hash only the first 100KB, the last 100KB,
/// and append the file size to the hash context.
pub fn computeFastHash(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, file_path, .{ .mode = .read_only });
    defer std.Io.File.close(file, io);

    const size = try std.Io.File.length(file, io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    // Hash the file size (little-endian u64)
    var size_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &size_buf, size, .little);
    hasher.update(&size_buf);

    if (size < 2 * 1024 * 1024) {
        // For small files, read the entire file
        if (size > 0) {
            const file_buf = try allocator.alloc(u8, size);
            defer allocator.free(file_buf);
            const bytes_read = try std.Io.File.readPositionalAll(file, io, file_buf, 0);
            hasher.update(file_buf[0..bytes_read]);
        }
    } else {
        const chunk_size = 100 * 1024;
        var head_buf: [chunk_size]u8 = undefined;
        const head_read = try std.Io.File.readPositionalAll(file, io, &head_buf, 0);
        hasher.update(head_buf[0..head_read]);

        var tail_buf: [chunk_size]u8 = undefined;
        const tail_pos = size - chunk_size;
        const tail_read = try std.Io.File.readPositionalAll(file, io, &tail_buf, tail_pos);
        hasher.update(tail_buf[0..tail_read]);
    }

    var hash_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&hash_bytes);

    const hex = std.fmt.bytesToHex(hash_bytes, .lower);
    return try allocator.dupe(u8, &hex);
}

test "computeFastHash: small and large files" {
    const testing_allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_utils = @import("test_utils.zig");

    var temp_ctx = try test_utils.TempDirContext.init(testing_allocator, io);
    defer temp_ctx.cleanup();

    const small_path = try std.fs.path.join(testing_allocator, &.{ temp_ctx.abs_path, "small.txt" });
    defer testing_allocator.free(small_path);
    const large_path = try std.fs.path.join(testing_allocator, &.{ temp_ctx.abs_path, "large.txt" });
    defer testing_allocator.free(large_path);

    // Create small file (< 2MB)
    const small_file = try std.Io.Dir.createFile(temp_ctx.tmp.dir, io, "small.txt", .{});
    try std.Io.File.writePositionalAll(small_file, io, "Hello, Antigravity!", 0);
    std.Io.File.close(small_file, io);

    // Create large file (>= 2MB)
    const large_file = try std.Io.Dir.createFile(temp_ctx.tmp.dir, io, "large.txt", .{});
    defer std.Io.File.close(large_file, io);

    // Write 2.5 MB of data
    const chunk_size = 64 * 1024;
    var data: [chunk_size]u8 = undefined;
    @memset(&data, 'A');
    var offset: u64 = 0;
    while (offset < 25 * 100 * 1024) {
        try std.Io.File.writePositionalAll(large_file, io, &data, offset);
        offset += chunk_size;
    }

    const hash1 = try computeFastHash(io, testing_allocator, small_path);
    defer testing_allocator.free(hash1);

    const hash2 = try computeFastHash(io, testing_allocator, large_path);
    defer testing_allocator.free(hash2);

    try std.testing.expect(hash1.len == 64);
    try std.testing.expect(hash2.len == 64);
    try std.testing.expect(!std.mem.eql(u8, hash1, hash2));
}
