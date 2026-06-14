const std = @import("std");

/// Test helper for creating an isolated temporary directory and its absolute path.
pub const TempDirContext = struct {
    tmp: std.testing.TmpDir,
    abs_path: [:0]u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: anytype) !TempDirContext {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const temp_rel_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer allocator.free(temp_rel_path);

        const abs_path = try std.Io.Dir.cwd().realPathFileAlloc(io, temp_rel_path, allocator);

        return .{
            .tmp = tmp,
            .abs_path = abs_path,
            .allocator = allocator,
        };
    }

    pub fn cleanup(self: *TempDirContext) void {
        self.allocator.free(self.abs_path);
        self.tmp.cleanup();
    }
};
