//! Orchestration pipeline for compilation, staging, and remote execution.

const std = @import("std");
const test_utils = @import("../core/test_utils.zig");
const service = @import("service.zig");
const options = @import("options.zig");

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

/// Spawns a subprocess and feeds data to stdin, waiting for completion.
pub fn runCommandWithInput(io: std.Io, argv: []const []const u8, input: []const u8) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .inherit,
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print("Failed to start command '{s}': {s}\n", .{ argv[0], @errorName(err) });
        return err;
    };

    if (child.stdin) |in_file| {
        _ = std.Io.File.writeStreamingAll(in_file, io, input) catch {};
        if (input.len == 0 or input[input.len - 1] != '\n') {
            _ = std.Io.File.writeStreamingAll(in_file, io, "\n") catch {};
        }
        std.Io.File.close(in_file, io);
        child.stdin = null;
    }

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
    exec_path: ?[]const u8,
) ![]u8 {
    return service.generateServiceUnit(allocator, .{
        .user = user,
        .working_dir = working_dir,
        .exec_path = exec_path orelse options.default_exec_path,
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
    exec_path: ?[]const u8,
) !void {
    const unit = try generateServiceUnitContent(allocator, user, remote_dir, port, db_path, auth_user, auth_pass, exec_path);
    defer allocator.free(unit);

    try writeServiceFile(io, allocator, output, unit);
    if (!std.mem.eql(u8, output, "-")) {
        std.debug.print("[deploy] Service file generated at {s}\n", .{output});
    }
}

/// Holds parsed systemd service properties discovered from a remote host.
pub const RemoteServiceInfo = struct {
    is_installed: bool = false,
    exec_path: ?[]const u8 = null,
    working_dir: ?[]const u8 = null,
    user: ?[]const u8 = null,
    fragment_path: ?[]const u8 = null,
    port: ?u16 = null,
    db_path: ?[]const u8 = null,
    auth_user: ?[]const u8 = null,
    auth_pass: ?[]const u8 = null,

    pub fn deinit(self: *RemoteServiceInfo, allocator: std.mem.Allocator) void {
        if (self.exec_path) |p| allocator.free(p);
        if (self.working_dir) |w| allocator.free(w);
        if (self.user) |u| allocator.free(u);
        if (self.fragment_path) |f| allocator.free(f);
        if (self.db_path) |d| allocator.free(d);
        if (self.auth_user) |u| allocator.free(u);
        if (self.auth_pass) |p| allocator.free(p);
        self.* = .{};
    }
};

fn findTokenEnd(s: []const u8) usize {
    for (s, 0..) |c, i| {
        if (c == ' ' or c == ';' or c == '}' or c == '\r' or c == '\n') {
            return i;
        }
    }
    return s.len;
}

fn extractArgValue(s: []const u8, flag: []const u8) ?[]const u8 {
    var search_idx: usize = 0;
    while (std.mem.indexOfPos(u8, s, search_idx, flag)) |idx| {
        const after_flag = idx + flag.len;
        if (after_flag < s.len and (s[after_flag] == ' ' or s[after_flag] == '=')) {
            var val_start = after_flag + 1;
            while (val_start < s.len and s[val_start] == ' ') : (val_start += 1) {}
            const val_len = findTokenEnd(s[val_start..]);
            if (val_len > 0) {
                return s[val_start .. val_start + val_len];
            }
        }
        search_idx = after_flag;
    }
    return null;
}

fn extractEnvVar(allocator: std.mem.Allocator, s: []const u8, var_name: []const u8) ?[]const u8 {
    var search_idx: usize = 0;
    while (std.mem.indexOfPos(u8, s, search_idx, var_name)) |idx| {
        const after_name = idx + var_name.len;
        if (after_name < s.len and s[after_name] == '=') {
            const val_start = after_name + 1;
            var val_end = val_start;
            while (val_end < s.len and s[val_end] != ' ' and s[val_end] != '"' and s[val_end] != '\'' and s[val_end] != '\r' and s[val_end] != '\n') : (val_end += 1) {}
            const raw = s[val_start..val_end];
            if (raw.len > 0) {
                return allocator.dupe(u8, raw) catch null;
            }
        }
        search_idx = after_name;
    }
    return null;
}

/// Parses output from `systemctl show zprobe-server.service` into structured service details.
pub fn parseRemoteServiceOutput(allocator: std.mem.Allocator, output: []const u8) RemoteServiceInfo {
    var info = RemoteServiceInfo{};

    var line_iter = std.mem.splitScalar(u8, output, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r \t");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "LoadState=")) {
            const val = line["LoadState=".len..];
            if (std.mem.eql(u8, val, "loaded")) {
                info.is_installed = true;
            }
        } else if (std.mem.startsWith(u8, line, "FragmentPath=")) {
            const val = line["FragmentPath=".len..];
            if (val.len > 0) {
                info.fragment_path = allocator.dupe(u8, val) catch null;
            }
        } else if (std.mem.startsWith(u8, line, "WorkingDirectory=")) {
            const val = line["WorkingDirectory=".len..];
            if (val.len > 0) {
                info.working_dir = allocator.dupe(u8, val) catch null;
            }
        } else if (std.mem.startsWith(u8, line, "User=")) {
            const val = line["User=".len..];
            if (val.len > 0) {
                info.user = allocator.dupe(u8, val) catch null;
            }
        } else if (std.mem.startsWith(u8, line, "Environment=")) {
            const val = line["Environment=".len..];
            if (extractEnvVar(allocator, val, "ZPROBE_AUTH_USER")) |u| {
                info.auth_user = u;
            }
            if (extractEnvVar(allocator, val, "ZPROBE_AUTH_PASS")) |p| {
                info.auth_pass = p;
            }
        } else if (std.mem.startsWith(u8, line, "ExecStart=")) {
            const val = line["ExecStart=".len..];
            if (std.mem.indexOf(u8, val, "path=")) |idx| {
                const path_start = idx + "path=".len;
                const path_end = findTokenEnd(val[path_start..]);
                const raw_path = val[path_start .. path_start + path_end];
                if (raw_path.len > 0) {
                    info.exec_path = allocator.dupe(u8, raw_path) catch null;
                }
            }
            if (std.mem.indexOf(u8, val, "argv[]=")) |idx| {
                const argv_str = val[idx + "argv[]=".len ..];
                if (extractArgValue(argv_str, "--port")) |port_str| {
                    if (std.fmt.parseInt(u16, port_str, 10)) |p| {
                        info.port = p;
                    } else |_| {}
                }
                if (extractArgValue(argv_str, "--db")) |db_str| {
                    info.db_path = allocator.dupe(u8, db_str) catch null;
                }
            }
        }
    }

    return info;
}

/// Queries a remote host via SSH to inspect any existing zprobe-server systemd unit.
pub fn inspectRemoteService(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    ssh_port: u16,
) RemoteServiceInfo {
    const port_str = std.fmt.allocPrint(allocator, "{d}", .{ssh_port}) catch return .{};
    defer allocator.free(port_str);

    const query_cmd = "systemctl show zprobe-server.service -p LoadState -p FragmentPath -p ExecStart -p WorkingDirectory -p User -p Environment 2>/dev/null || true";
    const run_res = std.process.run(allocator, io, .{
        .argv = &.{ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-p", port_str, host, query_cmd },
    }) catch return .{};
    defer allocator.free(run_res.stdout);
    defer allocator.free(run_res.stderr);

    return parseRemoteServiceOutput(allocator, run_res.stdout);
}

/// Builds, syncs, installs, and activates zprobe and zprobe-server on the remote host via SSH/rsync.
pub fn runInstall(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    ssh_port: u16,
    user: ?[]const u8,
    remote_dir: ?[]const u8,
    port: ?u16,
    db: ?[]const u8,
    exec_path: ?[]const u8,
    target: []const u8,
    auth_user: ?[]const u8,
    auth_pass: ?[]const u8,
    sudo_password: ?[]const u8,
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

    // 1. Inspect remote host for active systemd service to inherit existing paths and configuration
    std.debug.print("[deploy] Inspecting remote host {s} for active systemd configuration...\n", .{host});
    var remote_info = inspectRemoteService(io, allocator, host, ssh_port);
    defer remote_info.deinit(allocator);

    const effective_remote_dir = remote_dir orelse remote_info.working_dir orelse {
        std.debug.print("Error: No active service found on remote host; --remote-dir <path> is required for initial installation.\n", .{});
        return error.MissingRemoteDir;
    };
    const effective_exec_path = exec_path orelse remote_info.exec_path orelse options.default_exec_path;
    const effective_port = port orelse remote_info.port orelse options.default_port;
    const effective_user = user orelse remote_info.user orelse (options.extractUserFromHost(host) orelse return error.MissingUserValue);
    const effective_auth_user = auth_user orelse remote_info.auth_user;
    const effective_auth_pass = auth_pass orelse remote_info.auth_pass;
    const effective_unit_dest = remote_info.fragment_path orelse "/etc/systemd/system/zprobe-server.service";

    var allocated_db: ?[]const u8 = null;
    defer if (allocated_db) |d| allocator.free(d);
    const effective_db = if (db) |d| d else if (remote_info.db_path) |d| d else blk: {
        allocated_db = try std.fmt.allocPrint(allocator, "{s}/zprobe_cache.db", .{effective_remote_dir});
        break :blk allocated_db.?;
    };

    if (remote_info.is_installed) {
        std.debug.print("[deploy] Active systemd service detected:\n", .{});
        std.debug.print("         Unit Path: {s}\n", .{effective_unit_dest});
        std.debug.print("         Exec Path: {s}\n", .{effective_exec_path});
        std.debug.print("         Working Dir: {s}\n", .{effective_remote_dir});
        std.debug.print("         User: {s}\n", .{effective_user});
        std.debug.print("         Port: {d}\n", .{effective_port});
        std.debug.print("         DB: {s}\n", .{effective_db});
    } else {
        std.debug.print("[deploy] No existing service found; configuring new installation:\n", .{});
        std.debug.print("         Exec Path: {s}\n", .{effective_exec_path});
        std.debug.print("         Remote Dir: {s}\n", .{effective_remote_dir});
    }

    // 2. Pre-flight: ensure remote destination directory exists, is owned by user, and prune legacy binaries
    std.debug.print("[deploy] Pre-flight: preparing remote directory...\n", .{});
    const preflight_inner = try std.fmt.allocPrint(
        allocator,
        "mkdir -p \"{s}\" && chown \"{s}\" \"{s}\" && (rm -f \"{s}/zprobe-synology\"* \"{s}/zprobe-server-synology\"* 2>/dev/null || true)",
        .{ effective_remote_dir, effective_user, effective_remote_dir, effective_remote_dir, effective_remote_dir },
    );
    defer allocator.free(preflight_inner);

    if (sudo_password) |sp| {
        const preflight_cmd = try std.fmt.allocPrint(
            allocator,
            "sudo -S -p '' sh -c '{s}'",
            .{preflight_inner},
        );
        defer allocator.free(preflight_cmd);
        _ = runCommandWithInput(io, &.{ "ssh", "-p", port_str, host, preflight_cmd }, sp) catch {};
    } else {
        const preflight_cmd = try std.fmt.allocPrint(
            allocator,
            "mkdir -p \"{s}\" && (rm -f \"{s}/zprobe-synology\"* \"{s}/zprobe-server-synology\"* 2>/dev/null || true)",
            .{ effective_remote_dir, effective_remote_dir, effective_remote_dir },
        );
        defer allocator.free(preflight_cmd);
        _ = runCommand(io, &.{ "ssh", "-p", port_str, host, preflight_cmd }) catch {};
    }

    // 3. Stage deployment artifacts locally with canonical names (zprobe, zprobe-server)
    const staging_dir = try std.fs.path.join(allocator, &.{ "zig-out", "deploy-staging" });
    defer allocator.free(staging_dir);

    const cwd = std.Io.Dir.cwd();
    std.Io.Dir.createDirPath(cwd, io, staging_dir) catch |err| {
        if (err != error.PathAlreadyExists and err != error.DirExists) return err;
    };
    defer {
        std.Io.Dir.deleteTree(cwd, io, staging_dir) catch {};
    }

    const staged_cli_path = try std.fs.path.join(allocator, &.{ staging_dir, "zprobe" });
    defer allocator.free(staged_cli_path);

    const staged_server_path = try std.fs.path.join(allocator, &.{ staging_dir, "zprobe-server" });
    defer allocator.free(staged_server_path);

    const staged_service_path = try std.fs.path.join(allocator, &.{ staging_dir, "zprobe-server.service" });
    defer allocator.free(staged_service_path);

    try std.Io.Dir.copyFile(cwd, cli_binary_path, cwd, staged_cli_path, io, .{});
    try std.Io.Dir.copyFile(cwd, server_binary_path, cwd, staged_server_path, io, .{});

    const service_unit = try generateServiceUnitContent(
        allocator,
        effective_user,
        effective_remote_dir,
        effective_port,
        effective_db,
        effective_auth_user,
        effective_auth_pass,
        effective_exec_path,
    );
    defer allocator.free(service_unit);

    try writeServiceFile(io, allocator, staged_service_path, service_unit);

    // 4. Rsync canonical artifacts to remote destination directory
    const rsync_dest = try std.fmt.allocPrint(allocator, "{s}:{s}/", .{ host, effective_remote_dir });
    defer allocator.free(rsync_dest);

    std.debug.print("[deploy] Syncing canonical binaries and service unit to {s} (SSH port {d})...\n", .{ rsync_dest, ssh_port });
    const rsync_rsh = try std.fmt.allocPrint(allocator, "ssh -p {d}", .{ssh_port});
    defer allocator.free(rsync_rsh);

    runCommand(io, &.{ "rsync", "-avz", "--progress", "-e", rsync_rsh, staged_cli_path, staged_server_path, staged_service_path, rsync_dest }) catch return error.SyncFailed;

    // 5. Remote installation script: install to effective systemd paths
    const db_dir = std.fs.path.dirname(effective_db) orelse effective_remote_dir;
    const target_bin_dir = std.fs.path.dirname(effective_exec_path) orelse "/usr/local/bin";
    const cli_dest = try std.fs.path.join(allocator, &.{ target_bin_dir, "zprobe" });
    defer allocator.free(cli_dest);
    const unit_dir = std.fs.path.dirname(effective_unit_dest) orelse "/etc/systemd/system";

    const is_same_bin_dir = std.mem.eql(u8, target_bin_dir, effective_remote_dir);

    const install_cmds = if (!is_same_bin_dir)
        try std.fmt.allocPrint(
            allocator,
            \\install -m 755 "{s}/zprobe" "{s}" && \
            \\install -m 755 "{s}/zprobe-server" "{s}" && \
        ,
            .{ effective_remote_dir, cli_dest, effective_remote_dir, effective_exec_path },
        )
    else
        try allocator.dupe(u8, "");
    defer allocator.free(install_cmds);

    const inner_script = try std.fmt.allocPrint(
        allocator,
        \\(systemctl stop zprobe-server.service 2>/dev/null || true) && \
        \\mkdir -p "{s}" "{s}" "{s}" "{s}" && \
        \\chown "{s}" "{s}" "{s}" && \
        \\chmod 755 "{s}/zprobe" "{s}/zprobe-server" && \
        \\{s}install -m 644 "{s}/zprobe-server.service" "{s}" && \
        \\systemctl daemon-reload && \
        \\systemctl enable zprobe-server.service && \
        \\systemctl restart zprobe-server.service && \
        \\(systemctl is-active --quiet zprobe-server.service || (journalctl -u zprobe-server.service -n 20 --no-pager && false))
    ,
        .{
            target_bin_dir,
            unit_dir,
            db_dir,
            effective_remote_dir,
            effective_user,
            effective_remote_dir,
            db_dir,
            effective_remote_dir,
            effective_remote_dir,
            install_cmds,
            effective_remote_dir,
            effective_unit_dest,
        },
    );
    defer allocator.free(inner_script);

    std.debug.print("[deploy] Installing binaries and activating systemd service on {s}...\n", .{host});
    if (sudo_password) |sp| {
        const remote_cmd = try std.fmt.allocPrint(allocator, "sudo -S -p '' sh -c '{s}'", .{inner_script});
        defer allocator.free(remote_cmd);
        runCommandWithInput(io, &.{ "ssh", "-p", port_str, host, remote_cmd }, sp) catch return error.RemoteExecutionFailed;
    } else {
        const remote_cmd = try std.fmt.allocPrint(allocator, "sudo sh -c '{s}'", .{inner_script});
        defer allocator.free(remote_cmd);
        runCommand(io, &.{ "ssh", "-p", port_str, "-t", host, remote_cmd }) catch return error.RemoteExecutionFailed;
    }

    std.debug.print("[deploy] Verification succeeded; zprobe-server is active.\n", .{});
}

test "generateServiceUnitContent creates expected systemd unit structure" {
    const allocator = std.testing.allocator;
    const unit = try generateServiceUnitContent(allocator, "admin", "/volume1/docker/zprobe", 8085, "/volume1/docker/zprobe/zprobe_cache.db", null, null, null);
    defer allocator.free(unit);

    try std.testing.expect(std.mem.find(u8, unit, "Description=zprobe Insights Server") != null);
    try std.testing.expect(std.mem.find(u8, unit, "User=admin") != null);
    try std.testing.expect(std.mem.find(u8, unit, "WorkingDirectory=/volume1/docker/zprobe") != null);
    try std.testing.expect(std.mem.find(u8, unit, "ExecStart=/usr/local/bin/zprobe-server --port 8085 --db /volume1/docker/zprobe/zprobe_cache.db") != null);
    try std.testing.expect(std.mem.find(u8, unit, "Restart=on-failure") != null);
    try std.testing.expect(std.mem.find(u8, unit, "WantedBy=multi-user.target") != null);
}

test "generateServiceUnitContent with custom exec_path sets ExecStart path" {
    const allocator = std.testing.allocator;
    const unit = try generateServiceUnitContent(allocator, "admin", "/volume1/docker/zprobe", 8085, "/volume1/docker/zprobe/zprobe_cache.db", null, null, "/volume1/docker/zprobe/zprobe-server");
    defer allocator.free(unit);

    try std.testing.expect(std.mem.find(u8, unit, "ExecStart=/volume1/docker/zprobe/zprobe-server --port 8085 --db /volume1/docker/zprobe/zprobe_cache.db") != null);
}

test "generateServiceUnitContent with basic auth injects Environment directives" {
    const allocator = std.testing.allocator;
    const unit = try generateServiceUnitContent(allocator, "admin", "/volume1/docker/zprobe", 8085, "/volume1/docker/zprobe/zprobe_cache.db", "admin_user", "supersecret", null);
    defer allocator.free(unit);

    try std.testing.expect(std.mem.find(u8, unit, "Environment=\"ZPROBE_AUTH_USER=admin_user\"") != null);
    try std.testing.expect(std.mem.find(u8, unit, "Environment=\"ZPROBE_AUTH_PASS=supersecret\"") != null);
}

test "parseRemoteServiceOutput parses active service properties" {
    const allocator = std.testing.allocator;
    const sample =
        \\ExecStart={ path=/usr/local/bin/zprobe-server ; argv[]=/usr/local/bin/zprobe-server --port 8085 --db /volume1/docker/zprobe/zprobe_cache.db ; ignore_errors=no ; start_time=[Sun 2026-10-04 17:45:39 PDT] ; stop_time=[n/a] ; pid=331 ; code=(null) ; status=0/0 }
        \\Environment="ZPROBE_AUTH_USER=nasadmin" "ZPROBE_AUTH_PASS=secret123"
        \\WorkingDirectory=/volume1/docker/zprobe
        \\User=sunbunbun
        \\LoadState=loaded
        \\FragmentPath=/etc/systemd/system/zprobe-server.service
    ;

    var info = parseRemoteServiceOutput(allocator, sample);
    defer info.deinit(allocator);

    try std.testing.expect(info.is_installed);
    try std.testing.expectEqualStrings("/usr/local/bin/zprobe-server", info.exec_path.?);
    try std.testing.expectEqualStrings("/volume1/docker/zprobe", info.working_dir.?);
    try std.testing.expectEqualStrings("sunbunbun", info.user.?);
    try std.testing.expectEqualStrings("/etc/systemd/system/zprobe-server.service", info.fragment_path.?);
    try std.testing.expectEqual(@as(?u16, 8085), info.port);
    try std.testing.expectEqualStrings("/volume1/docker/zprobe/zprobe_cache.db", info.db_path.?);
    try std.testing.expectEqualStrings("nasadmin", info.auth_user.?);
    try std.testing.expectEqualStrings("secret123", info.auth_pass.?);
}

test "parseRemoteServiceOutput handles SSH warning banners and custom working directories" {
    const allocator = std.testing.allocator;
    const sample =
        \\** WARNING: connection is not using a post-quantum key exchange algorithm.
        \\** This session may be vulnerable to "store now, decrypt later" attacks.
        \\** The server may need to be upgraded. See https://openssh.com/pq.html
        \\ExecStart={ path=/volume1/docker/zprobe/zprobe-server ; argv[]=/volume1/docker/zprobe/zprobe-server --port 9000 --db /volume1/docker/zprobe/custom.db ; ignore_errors=no }
        \\Environment=
        \\WorkingDirectory=/volume1/docker/zprobe
        \\User=sunbunbun
        \\LoadState=loaded
        \\FragmentPath=/etc/systemd/system/zprobe-server.service
    ;

    var info = parseRemoteServiceOutput(allocator, sample);
    defer info.deinit(allocator);

    try std.testing.expect(info.is_installed);
    try std.testing.expectEqualStrings("/volume1/docker/zprobe/zprobe-server", info.exec_path.?);
    try std.testing.expectEqualStrings("/volume1/docker/zprobe", info.working_dir.?);
    try std.testing.expectEqualStrings("sunbunbun", info.user.?);
    try std.testing.expectEqualStrings("/etc/systemd/system/zprobe-server.service", info.fragment_path.?);
    try std.testing.expectEqual(@as(?u16, 9000), info.port);
    try std.testing.expectEqualStrings("/volume1/docker/zprobe/custom.db", info.db_path.?);
    try std.testing.expect(info.auth_user == null);
    try std.testing.expect(info.auth_pass == null);
}

test "parseRemoteServiceOutput handles not-found service cleanly" {
    const allocator = std.testing.allocator;
    const sample =
        \\Environment=
        \\WorkingDirectory=
        \\User=
        \\LoadState=not-found
        \\FragmentPath=
    ;

    var info = parseRemoteServiceOutput(allocator, sample);
    defer info.deinit(allocator);

    try std.testing.expect(!info.is_installed);
    try std.testing.expect(info.exec_path == null);
    try std.testing.expect(info.working_dir == null);
    try std.testing.expect(info.user == null);
    try std.testing.expect(info.fragment_path == null);
    try std.testing.expect(info.port == null);
    try std.testing.expect(info.db_path == null);
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

test "runCommandWithInput feeds input into child process stdin" {
    const io = std.testing.io;
    try runCommandWithInput(io, &.{ "sh", "-c", "read val && test \"$val\" = 'deploy_secret_test'" }, "deploy_secret_test");
}
