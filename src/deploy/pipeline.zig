//! Orchestration pipeline for compilation, staging, and remote execution.

const std = @import("std");
const test_utils = @import("../core/test_utils.zig");
const service = @import("service.zig");

/// Spawns a subprocess and waits for completion, checking for success.
pub fn runCommand(io: std.Io, argv: []const []const u8) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .inherit,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print("Failed to start command '{s}': {s}\n", .{ argv[0], @errorName(err) });
        return err;
    };

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("Command failed with exit code {d}: {s}\n", .{ code, argv[0] });
                return error.CommandFailed;
            }
        },
        else => {
            std.debug.print("Command terminated unexpectedly: {s}\n", .{argv[0]});
            return error.CommandFailed;
        },
    }
}

/// Resolves the filesystem path to a built release binary, checking architecture-suffixed and generic names.
pub fn resolveBinaryPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: []const u8,
    base_name: []const u8,
) ![]const u8 {
    const candidate_names = [_][]const u8{
        try std.fmt.allocPrint(allocator, "{s}-{s}", .{ base_name, target }),
        try allocator.dupe(u8, base_name),
    };
    defer {
        for (candidate_names) |c| allocator.free(c);
    }

    const cwd = std.Io.Dir.cwd();
    for (candidate_names) |cand| {
        const full_path = try std.fs.path.join(allocator, &.{ "zig-out", "bin", cand });
        errdefer allocator.free(full_path);

        if (std.Io.Dir.openFile(cwd, io, full_path, .{ .mode = .read_only })) |file| {
            std.Io.File.close(file, io);
            return full_path;
        } else |_| {
            allocator.free(full_path);
        }
    }

    return error.BinaryNotFound;
}

/// Generates systemd service unit file content for the server daemon.
pub fn generateServiceUnitContent(
    allocator: std.mem.Allocator,
    user: []const u8,
    working_dir: []const u8,
    port: u16,
    db_path: []const u8,
    auth_user: ?[]const u8,
    auth_pass: ?[]const u8,
) ![]u8 {
    return service.generateServiceUnit(allocator, .{
        .user = user,
        .working_dir = working_dir,
        .exec_path = "/usr/local/bin/zprobe-server",
        .port = port,
        .db_path = db_path,
        .auth_user = if (auth_user) |u| (if (u.len > 0) u else null) else null,
        .auth_pass = if (auth_pass) |p| (if (p.len > 0) p else null) else null,
    });
}

/// Writes service unit content to a specified path, creating directories if needed, or writes to stdout if '-'.
pub fn writeServiceFile(io: std.Io, allocator: std.mem.Allocator, output_path: []const u8, content: []const u8) !void {
    _ = allocator;
    if (std.mem.eql(u8, output_path, "-")) {
        var stdout_buf: [8192]u8 = undefined;
        var writer = std.Io.File.Writer.init(.stdout(), io, &stdout_buf);
        try writer.interface.writeAll(content);
        try writer.flush();
        return;
    }

    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(output_path)) |parent| {
        if (parent.len > 0) {
            std.Io.Dir.createDirPath(cwd, io, parent) catch |err| {
                if (err != error.PathAlreadyExists and err != error.DirExists) return err;
            };
        }
    }

    const file = try std.Io.Dir.createFile(cwd, io, output_path, .{ .truncate = true, .read = false });
    defer std.Io.File.close(file, io);
    try std.Io.File.writePositionalAll(file, io, content, 0);
}

/// Executes local compilation of all release targets.
pub fn runBuild(io: std.Io, target: []const u8) !void {
    std.debug.print("[deploy] Building release targets for: {s}\n", .{target});
    const argv = [_][]const u8{ "zig", "build", "release-all" };
    runCommand(io, &argv) catch return error.BuildFailed;
    std.debug.print("[deploy] Build complete.\n", .{});
}

/// Generates and writes the systemd service file to the requested destination.
pub fn runService(
    io: std.Io,
    allocator: std.mem.Allocator,
    user: []const u8,
    remote_dir: []const u8,
    port: u16,
    db_path: []const u8,
    output: []const u8,
    auth_user: ?[]const u8,
    auth_pass: ?[]const u8,
) !void {
    const unit = try generateServiceUnitContent(allocator, user, remote_dir, port, db_path, auth_user, auth_pass);
    defer allocator.free(unit);

    try writeServiceFile(io, allocator, output, unit);
    if (!std.mem.eql(u8, output, "-")) {
        std.debug.print("[deploy] Service file generated at {s}\n", .{output});
    }
}

/// Builds, syncs, installs, and activates zprobe and zprobe-server on the remote host via SSH/rsync.
pub fn runInstall(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    ssh_port: u16,
    service_user: []const u8,
    remote_dir: []const u8,
    port: u16,
    db_path: []const u8,
    target: []const u8,
    auth_user: ?[]const u8,
    auth_pass: ?[]const u8,
) !void {
    try runBuild(io, target);

    const cli_binary_path = try resolveBinaryPath(allocator, io, target, "zprobe");
    defer allocator.free(cli_binary_path);

    const server_binary_path = try resolveBinaryPath(allocator, io, target, "zprobe-server");
    defer allocator.free(server_binary_path);

    std.debug.print("[deploy] Found CLI binary: {s}\n", .{cli_binary_path});
    std.debug.print("[deploy] Found server binary: {s}\n", .{server_binary_path});

    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{ssh_port});
    defer allocator.free(port_str);

    // 1. Single pre-flight SSH step: ensure remote staging directory exists and stop running service
    std.debug.print("[deploy] Pre-flight: preparing remote staging directory and stopping existing service...\n", .{});
    const preflight_cmd = try std.fmt.allocPrint(
        allocator,
        "mkdir -p \"{s}\" && (sudo systemctl stop zprobe-server.service 2>/dev/null || true)",
        .{remote_dir},
    );
    defer allocator.free(preflight_cmd);
    _ = runCommand(io, &.{ "ssh", "-p", port_str, "-t", host, preflight_cmd }) catch {};

    // 2. Generate service unit and stage locally to a temporary file
    const service_unit = try generateServiceUnitContent(allocator, service_user, remote_dir, port, db_path, auth_user, auth_pass);
    defer allocator.free(service_unit);

    const local_service_path = try std.fs.path.join(allocator, &.{ "zig-out", "zprobe-server.service" });
    defer allocator.free(local_service_path);

    try writeServiceFile(io, allocator, local_service_path, service_unit);
    defer std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, local_service_path) catch {};

    // 3. Rsync all 3 deployment artifacts (CLI, server, service unit) to remote staging directory
    const rsync_dest = try std.fmt.allocPrint(allocator, "{s}:{s}/", .{ host, remote_dir });
    defer allocator.free(rsync_dest);

    std.debug.print("[deploy] Syncing binaries and service unit to {s} (SSH port {d})...\n", .{ rsync_dest, ssh_port });
    const rsync_rsh = try std.fmt.allocPrint(allocator, "ssh -p {d}", .{ssh_port});
    defer allocator.free(rsync_rsh);

    runCommand(io, &.{ "rsync", "-avz", "--progress", "-e", rsync_rsh, cli_binary_path, server_binary_path, local_service_path, rsync_dest }) catch return error.SyncFailed;

    // 4. Remote installation script (no inline heredocs)
    const db_dir = std.fs.path.dirname(db_path) orelse remote_dir;
    const cli_file_name = std.fs.path.basename(cli_binary_path);
    const server_file_name = std.fs.path.basename(server_binary_path);
    const service_file_name = std.fs.path.basename(local_service_path);

    const remote_script = try std.fmt.allocPrint(
        allocator,
        \\sudo mkdir -p /usr/local/bin /etc/systemd/system "{s}" && \
        \\sudo chown "{s}" "{s}" && \
        \\sudo install -m 755 "{s}/{s}" /usr/local/bin/zprobe && \
        \\sudo install -m 755 "{s}/{s}" /usr/local/bin/zprobe-server && \
        \\sudo install -m 644 "{s}/{s}" /etc/systemd/system/zprobe-server.service && \
        \\sudo systemctl daemon-reload && \
        \\sudo systemctl enable zprobe-server.service && \
        \\sudo systemctl restart zprobe-server.service && \
        \\(sudo systemctl is-active --quiet zprobe-server.service || (sudo journalctl -u zprobe-server.service -n 20 --no-pager && false))
    ,
        .{ db_dir, service_user, db_dir, remote_dir, cli_file_name, remote_dir, server_file_name, remote_dir, service_file_name },
    );
    defer allocator.free(remote_script);

    std.debug.print("[deploy] Installing binaries and activating systemd service on {s}...\n", .{host});
    runCommand(io, &.{ "ssh", "-p", port_str, "-t", host, remote_script }) catch return error.RemoteExecutionFailed;

    std.debug.print("[deploy] Verification succeeded; zprobe-server is active.\n", .{});
}

test "generateServiceUnitContent creates expected systemd unit structure" {
    const allocator = std.testing.allocator;
    const unit = try generateServiceUnitContent(allocator, "admin", "/volume1/docker/zprobe", 8085, "/volume1/docker/zprobe/zprobe_cache.db", null, null);
    defer allocator.free(unit);

    try std.testing.expect(std.mem.indexOf(u8, unit, "Description=zprobe Insights Server") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "User=admin") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "WorkingDirectory=/volume1/docker/zprobe") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "ExecStart=/usr/local/bin/zprobe-server --port 8085 --db /volume1/docker/zprobe/zprobe_cache.db") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Restart=on-failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "WantedBy=multi-user.target") != null);
}

test "generateServiceUnitContent with basic auth injects Environment directives" {
    const allocator = std.testing.allocator;
    const unit = try generateServiceUnitContent(allocator, "admin", "/volume1/docker/zprobe", 8085, "/volume1/docker/zprobe/zprobe_cache.db", "admin_user", "supersecret");
    defer allocator.free(unit);

    try std.testing.expect(std.mem.indexOf(u8, unit, "Environment=\"ZPROBE_AUTH_USER=admin_user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Environment=\"ZPROBE_AUTH_PASS=supersecret\"") != null);
}

test "resolveBinaryPath resolves existing binary or reports not found without panicking" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Nonexistent binary fails gracefully with error.BinaryNotFound
    const err = resolveBinaryPath(allocator, io, "synology-arm64", "nonexistent-tool");
    try std.testing.expectError(error.BinaryNotFound, err);

    // Existing binary (if built in zig-out/bin) resolves without panicking on assert(isAbsolute)
    if (resolveBinaryPath(allocator, io, "synology-arm64", "zprobe")) |path| {
        defer allocator.free(path);
        try std.testing.expect(std.mem.endsWith(u8, path, "zprobe-synology-arm64") or std.mem.endsWith(u8, path, "zprobe"));
    } else |_| {}
}

test "writeServiceFile writes content and creates parent directories for relative paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer temp_ctx.cleanup();

    const test_path = try std.fs.path.join(allocator, &.{ temp_ctx.abs_path, "sub_dir", "test.service" });
    defer allocator.free(test_path);

    const test_content = "[Unit]\nDescription=Test\n";
    try writeServiceFile(io, allocator, test_path, test_content);

    const file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, test_path, .{ .mode = .read_only });
    defer std.Io.File.close(file, io);

    var buf: [64]u8 = undefined;
    const bytes_read = try std.Io.File.readPositionalAll(file, io, &buf, 0);
    try std.testing.expectEqualStrings(test_content, buf[0..bytes_read]);
}
