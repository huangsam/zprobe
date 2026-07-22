const std = @import("std");
const zprobe = @import("zprobe");
const Db = zprobe.db.Db;
const auth = @import("auth.zig");
const handlers = @import("handlers.zig");

pub fn handleConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    conn: std.Io.net.Stream,
    database: *Db,
    auth_user: ?[]const u8,
    auth_pass: ?[]const u8,
) !void {
    defer conn.close(io);

    var read_buffer: [16384]u8 = undefined;
    var write_buffer: [16384]u8 = undefined;
    var stream_reader = conn.reader(io, &read_buffer);
    var stream_writer = conn.writer(io, &write_buffer);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        var request = http_server.receiveHead() catch break;
        handleRequest(allocator, io, &request, database, auth_user, auth_pass) catch break;
    }
}

pub fn handleRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    database: *Db,
    auth_user: ?[]const u8,
    auth_pass: ?[]const u8,
) !void {
    const target_path = request.head.target;
    const method = request.head.method;

    if (auth_user != null and auth_pass != null) {
        if (!auth.isRequestAuthorized(request, auth_user.?, auth_pass.?)) {
            try request.respond("Unauthorized", .{
                .status = .unauthorized,
                .extra_headers = &.{
                    .{ .name = "WWW-Authenticate", .value = "Basic realm=\"zprobe\"" },
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }
    }

    const query_index = std.mem.indexOfScalar(u8, target_path, '?');
    const base_path = if (query_index) |idx| target_path[0..idx] else target_path;
    const query_string = if (query_index) |idx| target_path[idx + 1 ..] else "";

    if (std.mem.eql(u8, base_path, "/api/notes")) {
        try handlers.handleNotes(allocator, io, request, database, query_string);
        return;
    }

    if (method != .GET) {
        try request.respond("Method Not Allowed", .{
            .status = .method_not_allowed,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    }

    if (try handlers.handleStaticAsset(request, base_path)) {
        return;
    } else if (std.mem.eql(u8, base_path, "/api/stats")) {
        try handlers.handleStats(allocator, io, request, database);
    } else if (std.mem.eql(u8, base_path, "/api/thumbnail")) {
        try handlers.handleThumbnail(allocator, io, request, database, query_string);
    } else if (std.mem.eql(u8, base_path, "/api/file")) {
        try handlers.handleFile(allocator, io, request, database, query_string);
    } else if (std.mem.eql(u8, base_path, "/api/media")) {
        try handlers.handleMedia(allocator, io, request, database, query_string);
    } else {
        try request.respond("Not Found", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }
}
