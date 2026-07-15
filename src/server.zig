const std = @import("std");
const zprobe = @import("zprobe");
const Db = zprobe.db.Db;

const index_html = @embedFile("web/index.html");
const styles_css = @embedFile("web/styles.css");
const app_js = @embedFile("web/app.js");
const logo_svg = @embedFile("web/logo.svg");
const lucide_js = @embedFile("web/js/lucide.min.js");
const chart_js = @embedFile("web/js/chart.umd.js");
const font_outfit_600 = @embedFile("web/fonts/outfit-600.woff2");
const font_pj_400 = @embedFile("web/fonts/plus-jakarta-400.woff2");
const font_pj_600 = @embedFile("web/fonts/plus-jakarta-600.woff2");

fn computeWorkerCount(cpu_count: usize) usize {
    return @min(@max(cpu_count * 4, 8), 16);
}

const ConnectionPool = struct {
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    cond: std.Io.Condition = std.Io.Condition.init,
    queue: std.ArrayList(std.Io.net.Stream) = .empty,
    allocator: std.mem.Allocator,

    fn push(self: *ConnectionPool, io: std.Io, conn: std.Io.net.Stream) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.queue.append(self.allocator, conn) catch {
            conn.close(io);
        };
        self.cond.signal(io);
    }

    fn pop(self: *ConnectionPool, io: std.Io) std.Io.net.Stream {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.queue.items.len == 0) {
            self.cond.waitUncancelable(io, &self.mutex);
        }
        return self.queue.orderedRemove(0);
    }
};

const WorkerContext = struct {
    pool: *ConnectionPool,
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *Db,
};

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
        } else if (std.mem.eql(u8, arg, "--setup-service")) {
            var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
            const len = std.process.executablePath(io, &exe_buf) catch 0;
            const exe_path = if (len > 0) exe_buf[0..len] else "/usr/local/bin/zprobe-server";

            const work_dir = std.fs.path.dirname(exe_path) orelse "/usr/local/bin";

            const user = init.environ_map.get("USER") orelse init.environ_map.get("LOGNAME") orelse "zprobe";

            const db_abs_path = std.fs.path.resolve(allocator, &[_][]const u8{ work_dir, db_path }) catch db_path;
            defer if (!std.mem.eql(u8, db_abs_path, db_path)) allocator.free(db_abs_path);

            // Output service directly to stdout so it can be piped
            var stdout_buf: [1024]u8 = undefined;
            var writer = std.Io.File.Writer.init(.stdout(), io, &stdout_buf);
            const interface = &writer.interface;
            interface.print(
                \\[Unit]
                \\Description=zprobe Insights Server
                \\After=network.target
                \\
                \\[Service]
                \\Type=simple
                \\User={s}
                \\WorkingDirectory={s}
                \\ExecStart={s} --port {d} --db {s}
                \\Restart=on-failure
                \\RestartSec=5
                \\
                \\[Install]
                \\WantedBy=multi-user.target
                \\
            , .{ user, work_dir, exe_path, port, db_abs_path }) catch {};
            writer.flush() catch {};
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("zprobe-server: Insights for the zprobe SQLite cache.\n\n", .{});
            std.debug.print("Usage: zprobe-server [options]\n\n", .{});
            std.debug.print("Options:\n", .{});
            std.debug.print("  -p, --port <number>    Port to listen on (default: 8080)\n", .{});
            std.debug.print("  -d, --db <path>        Path to zprobe_cache.db (default: zprobe_cache.db)\n", .{});
            std.debug.print("  --setup-service        Generate and print a systemd service file tailored to this environment\n", .{});
            std.debug.print("  -h, --help             Show this help menu\n", .{});
            std.process.exit(0);
        } else {
            std.debug.print("Unknown option: '{s}'. Use --help for usage information.\n", .{arg});
            std.process.exit(1);
        }
    }

    const cwd = std.Io.Dir.cwd();
    const abs_db_path = blk: {
        const dir = std.fs.path.dirname(db_path) orelse ".";
        const abs_dir = cwd.realPathFileAlloc(io, dir, allocator) catch null;
        defer if (abs_dir) |path| allocator.free(path);
        const resolved_dir = if (abs_dir) |path| path else dir;
        break :blk try std.fs.path.join(allocator, &.{ resolved_dir, std.fs.path.basename(db_path) });
    };
    defer allocator.free(abs_db_path);

    var database = Db.init(allocator, abs_db_path) catch |err| {
        std.debug.print("Failed to initialize database at '{s}'. Error: {}\n", .{ db_path, err });
        std.process.exit(1);
    };
    defer database.deinit();

    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var pool: ConnectionPool = .{
        .allocator = allocator,
    };
    defer pool.queue.deinit(allocator);

    const cpu_count = std.Thread.getCpuCount() catch 4;
    const num_workers = computeWorkerCount(cpu_count);

    const threads = try allocator.alloc(std.Thread, num_workers);
    defer allocator.free(threads);

    const worker_ctx = WorkerContext{
        .pool = &pool,
        .allocator = allocator,
        .io = io,
        .database = &database,
    };

    var spawned_count: usize = 0;
    defer {
        for (threads[0..spawned_count]) |t| {
            t.join();
        }
    }

    for (0..num_workers) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerMain, .{worker_ctx});
        spawned_count += 1;
    }

    std.debug.print("---------------------------------------------------\n", .{});
    std.debug.print(" zprobe Insights Server running!\n", .{});
    std.debug.print(" Address:  http://0.0.0.0:{d}\n", .{port});
    std.debug.print(" Database: {s}\n", .{db_path});
    std.debug.print(" Workers:  {d}\n", .{num_workers});
    std.debug.print("---------------------------------------------------\n", .{});

    while (true) {
        const conn = server.accept(io) catch |err| {
            std.debug.print("Connection accept error: {}\n", .{err});
            continue;
        };
        pool.push(io, conn);
    }
}

fn workerMain(ctx: WorkerContext) void {
    while (true) {
        const conn = ctx.pool.pop(ctx.io);
        handleConnection(ctx.allocator, ctx.io, conn, ctx.database) catch {};
    }
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
        const new_res = allocator.dupe(u8, result[0..out_idx]) catch {
            allocator.free(result);
            return input;
        };
        allocator.free(result);
        return new_res;
    }
}

const MediaQueryParams = struct {
    limit: u32 = 25,
    offset: u32 = 0,
    search: ?[]const u8 = null,
    filter_format: ?[]const u8 = null,
    filter_type: ?[]const u8 = null,
    date_from: ?[]const u8 = null,
    date_to: ?[]const u8 = null,
    size_min: ?u64 = null,
    size_max: ?u64 = null,
    sort_by: ?[]const u8 = null,
    sort_order: ?[]const u8 = null,
};

fn parseMediaQueryParams(query_string: []const u8) MediaQueryParams {
    var params = MediaQueryParams{};
    var query_it = std.mem.splitScalar(u8, query_string, '&');
    while (query_it.next()) |param| {
        if (param.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const key = param[0..eq_idx];
        const val = param[eq_idx + 1 ..];

        if (std.mem.eql(u8, key, "limit")) {
            params.limit = std.fmt.parseInt(u32, val, 10) catch 25;
        } else if (std.mem.eql(u8, key, "offset")) {
            params.offset = std.fmt.parseInt(u32, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "search")) {
            params.search = val;
        } else if (std.mem.eql(u8, key, "format")) {
            params.filter_format = val;
        } else if (std.mem.eql(u8, key, "type")) {
            params.filter_type = val;
        } else if (std.mem.eql(u8, key, "date_from")) {
            params.date_from = val;
        } else if (std.mem.eql(u8, key, "date_to")) {
            params.date_to = val;
        } else if (std.mem.eql(u8, key, "size_min")) {
            params.size_min = std.fmt.parseInt(u64, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "size_max")) {
            params.size_max = std.fmt.parseInt(u64, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "sort")) {
            params.sort_by = val;
        } else if (std.mem.eql(u8, key, "order")) {
            params.sort_order = val;
        }
    }
    params.limit = std.math.clamp(params.limit, 1, 100);
    return params;
}

fn handleConnection(allocator: std.mem.Allocator, io: std.Io, conn: std.Io.net.Stream, database: *Db) !void {
    defer conn.close(io);

    var read_buffer: [16384]u8 = undefined;
    var write_buffer: [16384]u8 = undefined;
    var stream_reader = conn.reader(io, &read_buffer);
    var stream_writer = conn.writer(io, &write_buffer);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        var request = http_server.receiveHead() catch break;
        handleRequest(allocator, io, &request, database) catch break;
    }
}

fn handleRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    database: *Db,
) !void {
    const target_path = request.head.target;
    const method = request.head.method;

    const query_index = std.mem.indexOfScalar(u8, target_path, '?');
    const base_path = if (query_index) |idx| target_path[0..idx] else target_path;
    const query_string = if (query_index) |idx| target_path[idx + 1 ..] else "";

    if (method != .GET) {
        try request.respond("Method Not Allowed", .{
            .status = .method_not_allowed,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    }

    if (std.mem.eql(u8, base_path, "/") or std.mem.eql(u8, base_path, "/index.html")) {
        try request.respond(index_html, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/js/lucide.min.js")) {
        try request.respond(lucide_js, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/js/chart.umd.js")) {
        try request.respond(chart_js, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/fonts/outfit-600.woff2")) {
        try request.respond(font_outfit_600, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "font/woff2" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/fonts/plus-jakarta-400.woff2")) {
        try request.respond(font_pj_400, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "font/woff2" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/fonts/plus-jakarta-600.woff2")) {
        try request.respond(font_pj_600, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "font/woff2" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/styles.css")) {
        try request.respond(styles_css, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
                .{ .name = "Cache-Control", .value = "public, max-age=86400" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/app.js")) {
        try request.respond(app_js, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
                .{ .name = "Cache-Control", .value = "public, max-age=86400" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/logo.svg")) {
        try request.respond(logo_svg, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "image/svg+xml" },
                .{ .name = "Cache-Control", .value = "public, max-age=86400" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/api/stats")) {
        const stats = blk: {
            database.lockRead(io);
            defer database.unlockRead(io);
            break :blk database.getStatsCached(allocator, io) catch {
                try request.respond("Internal Server Error: Database Query Failed", .{
                    .status = .internal_server_error,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
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
            std.json.Stringify.value(stats, .{}, &aw.writer) catch {
                try request.respond("Internal Server Error: JSON Encoding Failed", .{
                    .status = .internal_server_error,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                    },
                });
                return;
            };
        }

        try request.respond(json_buf.items, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/api/thumbnail")) {
        var query_path: ?[]const u8 = null;
        var query_it = std.mem.splitScalar(u8, query_string, '&');
        while (query_it.next()) |param| {
            if (param.len == 0) continue;
            const eq_idx = std.mem.indexOfScalar(u8, param, '=') orelse continue;
            const key = param[0..eq_idx];
            const val = param[eq_idx + 1 ..];
            if (std.mem.eql(u8, key, "path")) {
                query_path = val;
            }
        }

        if (query_path == null) {
            try request.respond("Bad Request: missing 'path' parameter", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }

        const decoded_path = urlDecode(allocator, query_path.?);
        defer if (decoded_path.ptr != query_path.?.ptr) allocator.free(decoded_path);

        const db_dir = std.fs.path.dirname(database.db_path) orelse ".";
        const thumb_dir = try std.fs.path.join(allocator, &.{ db_dir, ".zprobe_thumbnails" });
        defer allocator.free(thumb_dir);

        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(decoded_path, &hash_bytes, .{});
        const hex_hash = std.fmt.bytesToHex(hash_bytes, .lower);
        const thumb_file_name = try std.fmt.allocPrint(allocator, "{s}.jpg", .{hex_hash});
        defer allocator.free(thumb_file_name);

        const thumb_abs_path = try std.fs.path.join(allocator, &.{ thumb_dir, thumb_file_name });
        defer allocator.free(thumb_abs_path);

        const file = std.Io.Dir.openFileAbsolute(io, thumb_abs_path, .{ .mode = .read_only }) catch |err| {
            if (err == error.FileNotFound) {
                // Heal the database cache desync: set has_thumbnail to 0.
                // Lock scope is kept tight so the write lock is released before
                // the HTTP respond() call below.
                {
                    database.lockWrite(io);
                    defer database.unlockWrite(io);
                    database.updateHasThumbnail(decoded_path, false) catch |db_err| {
                        std.debug.print("Failed to update has_thumbnail cache for '{s}': {}\n", .{ decoded_path, db_err });
                    };
                }
            }
            try request.respond("Not Found: thumbnail not generated", .{
                .status = .not_found,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };
        defer std.Io.File.close(file, io);

        const st = std.Io.File.stat(file, io) catch {
            try request.respond("Internal Server Error: stat failed", .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };

        const buf = try allocator.alloc(u8, st.size);
        defer allocator.free(buf);

        const bytes_read = try std.Io.File.readPositionalAll(file, io, buf, 0);
        if (bytes_read != st.size) {
            try request.respond("Internal Server Error: partial read", .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }

        try request.respond(buf, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "image/jpeg" },
                .{ .name = "Cache-Control", .value = "public, max-age=86400" },
            },
        });
    } else if (std.mem.eql(u8, base_path, "/api/media")) {
        const params = parseMediaQueryParams(query_string);

        const decoded_search = if (params.search) |s| urlDecode(allocator, s) else null;
        defer if (decoded_search) |ds| {
            if (ds.ptr != params.search.?.ptr) allocator.free(ds);
        };

        const decoded_format = if (params.filter_format) |f| urlDecode(allocator, f) else null;
        defer if (decoded_format) |df| {
            if (df.ptr != params.filter_format.?.ptr) allocator.free(df);
        };

        const decoded_type = if (params.filter_type) |t| urlDecode(allocator, t) else null;
        defer if (decoded_type) |dt| {
            if (dt.ptr != params.filter_type.?.ptr) allocator.free(dt);
        };

        const decoded_date_from = if (params.date_from) |df| urlDecode(allocator, df) else null;
        defer if (decoded_date_from) |ddf| {
            if (ddf.ptr != params.date_from.?.ptr) allocator.free(ddf);
        };

        const decoded_date_to = if (params.date_to) |dt| urlDecode(allocator, dt) else null;
        defer if (decoded_date_to) |ddt| {
            if (ddt.ptr != params.date_to.?.ptr) allocator.free(ddt);
        };

        const decoded_sort = if (params.sort_by) |sb| urlDecode(allocator, sb) else null;
        defer if (decoded_sort) |dsb| {
            if (dsb.ptr != params.sort_by.?.ptr) allocator.free(dsb);
        };

        const decoded_order = if (params.sort_order) |so| urlDecode(allocator, so) else null;
        defer if (decoded_order) |dso| {
            if (dso.ptr != params.sort_order.?.ptr) allocator.free(dso);
        };

        const result = blk: {
            database.lockRead(io);
            defer database.unlockRead(io);
            break :blk database.getRecordsPaged(
                allocator,
                params.limit,
                params.offset,
                decoded_search,
                decoded_format,
                decoded_type,
                decoded_date_from,
                decoded_date_to,
                params.size_min,
                params.size_max,
                decoded_sort,
                decoded_order,
            ) catch {
                try request.respond("Internal Server Error: Database Query Failed", .{
                    .status = .internal_server_error,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
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
            std.json.Stringify.value(result, .{}, &aw.writer) catch {
                try request.respond("Internal Server Error: JSON Encoding Failed", .{
                    .status = .internal_server_error,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                    },
                });
                return;
            };
        }

        try request.respond(json_buf.items, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
    } else {
        try request.respond("Not Found", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }
}

test "urlDecode parsing and fallback" {
    const allocator = std.testing.allocator;

    const decoded = urlDecode(allocator, "hello+world%20test");
    defer if (decoded.ptr != "hello+world%20test".ptr) allocator.free(decoded);

    try std.testing.expectEqualStrings("hello world test", decoded);

    const empty = urlDecode(allocator, "");
    defer if (empty.ptr != "".ptr) allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const invalid = urlDecode(allocator, "%xy");
    defer if (invalid.ptr != "%xy".ptr) allocator.free(invalid);
    try std.testing.expectEqualStrings("%xy", invalid);
}

test "parseMediaQueryParams limit clamping and parsing" {
    // 1. Default limit is 25 when limit is absent
    const params_default = parseMediaQueryParams("offset=10");
    try std.testing.expectEqual(@as(u32, 25), params_default.limit);
    try std.testing.expectEqual(@as(u32, 10), params_default.offset);

    // 2. Custom limit is parsed correctly
    const params_custom = parseMediaQueryParams("limit=50&offset=20&search=foo");
    try std.testing.expectEqual(@as(u32, 50), params_custom.limit);
    try std.testing.expectEqual(@as(u32, 20), params_custom.offset);
    try std.testing.expectEqualStrings("foo", params_custom.search.?);

    // 3. Limit is clamped to 100 if higher limit is requested
    const params_high = parseMediaQueryParams("limit=1000");
    try std.testing.expectEqual(@as(u32, 100), params_high.limit);

    // 4. Limit is clamped to 1 if 0 is requested
    const params_zero = parseMediaQueryParams("limit=0");
    try std.testing.expectEqual(@as(u32, 1), params_zero.limit);

    // 5. If limit parsing fails (non-numeric), it defaults to 25 and clamps
    const params_invalid = parseMediaQueryParams("limit=abc");
    try std.testing.expectEqual(@as(u32, 25), params_invalid.limit);

    // 6. Test all other parameters are parsed correctly
    const params_all = parseMediaQueryParams("limit=10&offset=5&search=hello&format=png&type=image&date_from=2023-01-01&date_to=2023-12-31&size_min=100&size_max=2000&sort=name&order=desc");
    try std.testing.expectEqual(@as(u32, 10), params_all.limit);
    try std.testing.expectEqual(@as(u32, 5), params_all.offset);
    try std.testing.expectEqualStrings("hello", params_all.search.?);
    try std.testing.expectEqualStrings("png", params_all.filter_format.?);
    try std.testing.expectEqualStrings("image", params_all.filter_type.?);
    try std.testing.expectEqualStrings("2023-01-01", params_all.date_from.?);
    try std.testing.expectEqualStrings("2023-12-31", params_all.date_to.?);
    try std.testing.expectEqual(@as(u64, 100), params_all.size_min.?);
    try std.testing.expectEqual(@as(u64, 2000), params_all.size_max.?);
    try std.testing.expectEqualStrings("name", params_all.sort_by.?);
    try std.testing.expectEqualStrings("desc", params_all.sort_order.?);
}
