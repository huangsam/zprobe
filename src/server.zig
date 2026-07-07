const std = @import("std");
const zprobe = @import("zprobe");
const Db = zprobe.db.Db;

const index_html = @embedFile("web/index.html");
const styles_css = @embedFile("web/styles.css");
const lucide_js = @embedFile("web/js/lucide.min.js");
const chart_js = @embedFile("web/js/chart.umd.js");
const font_outfit_600 = @embedFile("web/fonts/outfit-600.woff2");
const font_pj_400 = @embedFile("web/fonts/plus-jakarta-400.woff2");
const font_pj_600 = @embedFile("web/fonts/plus-jakarta-600.woff2");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var port: u16 = 8080;
    var db_path: []const u8 = "zprobe_cache.db";

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    var arg_idx: usize = 1;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (arg_idx + 1 < args.len) {
                arg_idx += 1;
                const port_str = args[arg_idx];
                port = std.fmt.parseInt(u16, port_str, 10) catch |err| {
                    std.debug.print("Invalid port number: '{s}'. Error: {}\n", .{ port_str, err });
                    std.process.exit(1);
                };
            } else {
                std.debug.print("Error: --port requires a value\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--db") or std.mem.eql(u8, arg, "-d")) {
            if (arg_idx + 1 < args.len) {
                arg_idx += 1;
                db_path = args[arg_idx];
            } else {
                std.debug.print("Error: --db requires a path value\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("zprobe-server: Web Dashboard for the zprobe SQLite cache.\n\n", .{});
            std.debug.print("Usage: zprobe-server [options]\n\n", .{});
            std.debug.print("Options:\n", .{});
            std.debug.print("  -p, --port <number>    Port to listen on (default: 8080)\n", .{});
            std.debug.print("  -d, --db <path>        Path to zprobe_cache.db (default: zprobe_cache.db)\n", .{});
            std.debug.print("  -h, --help             Show this help menu\n", .{});
            std.process.exit(0);
        } else {
            std.debug.print("Unknown option: '{s}'. Use --help for usage information.\n", .{arg});
            std.process.exit(1);
        }
    }

    // Try to open the SQLite database
    var database = Db.init(allocator, db_path) catch |err| {
        std.debug.print("Failed to initialize database at '{s}'. Error: {}\n", .{ db_path, err });
        std.process.exit(1);
    };
    defer database.deinit();

    // Listen on local interface (or change to 0.0.0.0 for external access)
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.debug.print("---------------------------------------------------\n", .{});
    std.debug.print(" zprobe Dashboard Server running!\n", .{});
    std.debug.print(" Address:  http://0.0.0.0:{d}\n", .{port});
    std.debug.print(" Database: {s}\n", .{db_path});
    std.debug.print("---------------------------------------------------\n", .{});

    var client_id: usize = 0;
    while (true) {
        const conn = server.accept(io) catch |err| {
            std.debug.print("Connection accept error: {}\n", .{err});
            continue;
        };
        client_id += 1;

        const ctx = ClientContext{
            .allocator = allocator,
            .io = io,
            .conn = conn,
            .database = &database,
            .client_id = client_id,
        };

        if (std.Thread.spawn(.{}, handleConnectionThread, .{ctx})) |thread| {
            thread.detach();
        } else |err| {
            std.debug.print("Failed to spawn client handler thread: {}\n", .{err});
            conn.close(io);
        }
    }
}

const ClientContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    conn: std.Io.net.Stream,
    database: *Db,
    client_id: usize,
};

fn handleConnectionThread(ctx: ClientContext) void {
    handleConnection(ctx.allocator, ctx.io, ctx.conn, ctx.database) catch |err| {
        std.debug.print("[Client #{d}] Request handling failed: {}\n", .{ ctx.client_id, err });
    };
}

fn urlDecode(allocator: std.mem.Allocator, input: []const u8) []const u8 {
    var result = allocator.alloc(u8, input.len) catch return input;
    var out_idx: usize = 0;
    var in_idx: usize = 0;
    while (in_idx < input.len) {
        const ch = input[in_idx];
        if (ch == '+') {
            result[out_idx] = ' ';
            out_idx += 1;
            in_idx += 1;
        } else if (ch == '%' and in_idx + 2 < input.len) {
            const hex = input[in_idx + 1 .. in_idx + 3];
            const val = std.fmt.parseInt(u8, hex, 16) catch {
                result[out_idx] = '%';
                out_idx += 1;
                in_idx += 1;
                continue;
            };
            result[out_idx] = val;
            out_idx += 1;
            in_idx += 3;
        } else {
            result[out_idx] = ch;
            out_idx += 1;
            in_idx += 1;
        }
    }
    if (allocator.resize(result, out_idx)) {
        return result[0..out_idx];
    } else {
        const new_res = allocator.dupe(u8, result[0..out_idx]) catch return result[0..out_idx];
        allocator.free(result);
        return new_res;
    }
}

fn handleConnection(allocator: std.mem.Allocator, io: std.Io, conn: std.Io.net.Stream, database: *Db) !void {
    defer conn.close(io);

    // 16KB buffers for reading and writing HTTP data
    var read_buffer: [16384]u8 = undefined;
    var write_buffer: [16384]u8 = undefined;
    var stream_reader = conn.reader(io, &read_buffer);
    var stream_writer = conn.writer(io, &write_buffer);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    var request = http_server.receiveHead() catch |err| {
        std.debug.print("Could not read HTTP request head: {}\n", .{err});
        return;
    };

    const target_path = request.head.target;
    const method = request.head.method;
    
    // Split query parameters out of the path
    const query_index = std.mem.indexOfScalar(u8, target_path, '?');
    const base_path = if (query_index) |idx| target_path[0..idx] else target_path;
    const query_string = if (query_index) |idx| target_path[idx + 1 ..] else "";

    std.debug.print("[HTTP] {s} {s}\n", .{ @tagName(method), base_path });

    if (method != .GET) {
        try request.respond("Method Not Allowed", .{
            .status = .method_not_allowed,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
                .{ .name = "Connection", .value = "close" },
            },
        });
        return;
    }

    if (std.mem.eql(u8, base_path, "/") or std.mem.eql(u8, base_path, "/index.html")) {
        try request.respond(index_html, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html" },
                .{ .name = "Connection", .value = "close" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/js/lucide.min.js")) {
        try request.respond(lucide_js, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
                .{ .name = "Connection", .value = "close" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/js/chart.umd.js")) {
        try request.respond(chart_js, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
                .{ .name = "Connection", .value = "close" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/fonts/outfit-600.woff2")) {
        try request.respond(font_outfit_600, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "font/woff2" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
                .{ .name = "Connection", .value = "close" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/fonts/plus-jakarta-400.woff2")) {
        try request.respond(font_pj_400, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "font/woff2" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
                .{ .name = "Connection", .value = "close" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/fonts/plus-jakarta-600.woff2")) {
        try request.respond(font_pj_600, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "font/woff2" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
                .{ .name = "Connection", .value = "close" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/styles.css")) {
        try request.respond(styles_css, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
                .{ .name = "Cache-Control", .value = "public, max-age=86400" },
                .{ .name = "Connection", .value = "close" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/api/stats")) {
        // Safe database locking for multi-threaded read/write
        const stats = blk: {
            database.mutex.lockUncancelable(io);
            defer database.mutex.unlock(io);
            break :blk database.getStats(allocator) catch |err| {
                std.debug.print("DB error fetching stats: {}\n", .{err});
                try request.respond("Internal Server Error: Database Query Failed", .{
                    .status = .internal_server_error,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                        .{ .name = "Connection", .value = "close" },
                    },
                });
                return;
            };
        };
        defer stats.deinit(allocator);

        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(allocator);

        {
            var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &json_buf);
            defer json_buf = aw.toArrayList();
            std.json.Stringify.value(stats, .{}, &aw.writer) catch |err| {
                std.debug.print("JSON serialization error: {}\n", .{err});
                try request.respond("Internal Server Error: JSON Encoding Failed", .{
                    .status = .internal_server_error,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                        .{ .name = "Connection", .value = "close" },
                    },
                });
                return;
            };
        }

        try request.respond(json_buf.items, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Connection", .value = "close" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/api/media")) {
        var limit: u32 = 50;
        var offset: u32 = 0;
        var search: ?[]const u8 = null;
        var filter_format: ?[]const u8 = null;
        var filter_type: ?[]const u8 = null;
        var sort_by: ?[]const u8 = null;
        var sort_order: ?[]const u8 = null;

        var query_it = std.mem.splitScalar(u8, query_string, '&');
        while (query_it.next()) |param| {
            if (param.len == 0) continue;
            const eq_idx = std.mem.indexOfScalar(u8, param, '=') orelse continue;
            const key = param[0..eq_idx];
            const val = param[eq_idx + 1 ..];

            if (std.mem.eql(u8, key, "limit")) {
                limit = std.fmt.parseInt(u32, val, 10) catch 50;
            } else if (std.mem.eql(u8, key, "offset")) {
                offset = std.fmt.parseInt(u32, val, 10) catch 0;
            } else if (std.mem.eql(u8, key, "search")) {
                search = val;
            } else if (std.mem.eql(u8, key, "format")) {
                filter_format = val;
            } else if (std.mem.eql(u8, key, "type")) {
                filter_type = val;
            } else if (std.mem.eql(u8, key, "sort")) {
                sort_by = val;
            } else if (std.mem.eql(u8, key, "order")) {
                sort_order = val;
            }
        }

        // URL decode all inputs
        const decoded_search = if (search) |s| urlDecode(allocator, s) else null;
        defer if (decoded_search) |ds| allocator.free(ds);
        
        const decoded_format = if (filter_format) |f| urlDecode(allocator, f) else null;
        defer if (decoded_format) |df| allocator.free(df);

        const decoded_type = if (filter_type) |t| urlDecode(allocator, t) else null;
        defer if (decoded_type) |dt| allocator.free(dt);

        const decoded_sort = if (sort_by) |sb| urlDecode(allocator, sb) else null;
        defer if (decoded_sort) |dsb| allocator.free(dsb);

        const decoded_order = if (sort_order) |so| urlDecode(allocator, so) else null;
        defer if (decoded_order) |dso| allocator.free(dso);

        // Fetch paginated rows from database
        const result = blk: {
            database.mutex.lockUncancelable(io);
            defer database.mutex.unlock(io);
            break :blk database.getRecordsPaged(
                allocator,
                limit,
                offset,
                decoded_search,
                decoded_format,
                decoded_type,
                decoded_sort,
                decoded_order,
            ) catch |err| {
                std.debug.print("DB error fetching records: {}\n", .{err});
                try request.respond("Internal Server Error: Database Query Failed", .{
                    .status = .internal_server_error,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                        .{ .name = "Connection", .value = "close" },
                    },
                });
                return;
            };
        };
        defer {
            for (result.records) |r| {
                r.deinit(allocator);
                allocator.free(r.path);
                allocator.free(r.format);
            }
            allocator.free(result.records);
        }

        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(allocator);

        {
            var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &json_buf);
            defer json_buf = aw.toArrayList();
            std.json.Stringify.value(result, .{}, &aw.writer) catch |err| {
                std.debug.print("JSON serialization error: {}\n", .{err});
                try request.respond("Internal Server Error: JSON Encoding Failed", .{
                    .status = .internal_server_error,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                        .{ .name = "Connection", .value = "close" },
                    },
                });
                return;
            };
        }

        try request.respond(json_buf.items, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Connection", .value = "close" },
            },
        });
    } else {
        try request.respond("Not Found", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
                .{ .name = "Connection", .value = "close" },
            },
        });
    }
}
