const std = @import("std");
const zprobe = @import("zprobe");
const Db = zprobe.db.Db;
const routes = @import("routes.zig");

pub const ConnectionPool = struct {
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    cond: std.Io.Condition = std.Io.Condition.init,
    queue: std.ArrayList(std.Io.net.Stream) = .empty,
    allocator: std.mem.Allocator,

    pub fn push(self: *ConnectionPool, io: std.Io, conn: std.Io.net.Stream) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.queue.append(self.allocator, conn) catch {
            conn.close(io);
        };
        self.cond.signal(io);
    }

    pub fn pop(self: *ConnectionPool, io: std.Io) std.Io.net.Stream {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.queue.items.len == 0) {
            self.cond.waitUncancelable(io, &self.mutex);
        }
        return self.queue.orderedRemove(0);
    }
};

pub const WorkerContext = struct {
    pool: *ConnectionPool,
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *Db,
    auth_user: ?[]const u8 = null,
    auth_pass: ?[]const u8 = null,
};

pub fn workerMain(ctx: WorkerContext) void {
    while (true) {
        const conn = ctx.pool.pop(ctx.io);
        routes.handleConnection(ctx.allocator, ctx.io, conn, ctx.database, ctx.auth_user, ctx.auth_pass) catch {};
    }
}
