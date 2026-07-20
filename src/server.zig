const std = @import("std");
const zprobe = @import("zprobe");
const Db = zprobe.db.Db;
const pool = @import("server/pool.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const env_user = init.environ_map.get("ZPROBE_AUTH_USER");
    const env_pass = init.environ_map.get("ZPROBE_AUTH_PASS");
    const has_auth = env_user != null and env_pass != null;
    const auth_user = if (has_auth) env_user else null;
    const auth_pass = if (has_auth) env_pass else null;

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

    var pool_inst: pool.ConnectionPool = .{
        .allocator = allocator,
    };
    defer pool_inst.queue.deinit(allocator);

    const cpu_count = std.Thread.getCpuCount() catch 4;
    const num_workers = zprobe.utils.computeWorkerCount(cpu_count);

    const threads = try allocator.alloc(std.Thread, num_workers);
    defer allocator.free(threads);

    const worker_ctx = pool.WorkerContext{
        .pool = &pool_inst,
        .allocator = allocator,
        .io = io,
        .database = &database,
        .auth_user = auth_user,
        .auth_pass = auth_pass,
    };

    var spawned_count: usize = 0;
    defer {
        for (threads[0..spawned_count]) |t| {
            t.join();
        }
    }

    for (0..num_workers) |i| {
        threads[i] = try std.Thread.spawn(.{}, pool.workerMain, .{worker_ctx});
        spawned_count += 1;
    }

    std.debug.print("---------------------------------------------------\n", .{});
    std.debug.print(" zprobe Insights Server running!\n", .{});
    std.debug.print(" Address:  http://0.0.0.0:{d}\n", .{port});
    std.debug.print(" Database: {s}\n", .{db_path});
    std.debug.print(" Workers:  {d}\n", .{num_workers});
    if (auth_user != null and auth_pass != null) {
        std.debug.print(" Auth:     Basic Authentication Enabled (User: {s})\n", .{auth_user.?});
    } else {
        std.debug.print(" Auth:     None (Authless Mode)\n", .{});
    }
    std.debug.print("---------------------------------------------------\n", .{});

    while (true) {
        const conn = server.accept(io) catch |err| {
            std.debug.print("Connection accept error: {}\n", .{err});
            continue;
        };
        pool_inst.push(io, conn);
    }
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("server/utils.zig");
    _ = @import("server/auth.zig");
    _ = @import("server/handlers.zig");
    _ = @import("server/routes.zig");
    _ = @import("server/pool.zig");
}
