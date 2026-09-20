//! Deployment automation CLI for cross-compiling, staging, and configuring zprobe services.
//!
//! Provides automated builds, systemd service unit generation, and remote SSH/rsync
//! deployment workflows targeting remote hosts and Synology NAS devices.

const std = @import("std");
const test_utils = @import("core/test_utils.zig");
const service = @import("server/service.zig");

const usage =
    \\Usage:
    \\  zprobe-deploy <command> [options]
    \\
    \\Commands:
    \\  build             Build target release binaries
    \\  service           Generate a systemd unit file for the server
    \\  install           Build, upload, and install the remote service and CLI
    \\  help              Show this help text
    \\
    \\Options:
    \\  --host <user@host> Remote SSH host (required for install, supports user@host:port)
    \\  --ssh-port <port>  Remote SSH port (default: 22)
    \\  --user <username>  Systemd service user (default: parsed from --host, required for service)
    \\  --remote-dir <path> Remote staging directory (default: /volume1/docker/zprobe)
    \\  --port <port>      Server listen port (default: 8085)
    \\  --db <path>        Path to SQLite cache DB on remote host
    \\                     (default: /volume1/docker/zprobe/zprobe_cache.db)
    \\  --auth-user <name> HTTP basic auth user for dashboard (env: ZPROBE_AUTH_USER)
    \\  --auth-pass <pass> HTTP basic auth password for dashboard (env: ZPROBE_AUTH_PASS)
    \\  --output <path>    Output file for 'service' command (- for stdout)
    \\  --target <name>    Target architecture name (default: synology-arm64)
    \\
    \\Examples:
    \\  zprobe-deploy build
    \\  zprobe-deploy service --user admin --port 8085 --auth-user admin --auth-pass secret
    \\  zprobe-deploy install --host admin@nas.local:2222 --remote-dir /volume1/docker/zprobe
    \\
;

/// Default target architecture for release builds and remote installation.
pub const default_target = "synology-arm64";
/// Default remote directory path for staging binaries and unit files.
pub const default_remote_dir = "/volume1/docker/zprobe";
/// Default HTTP server listen port.
pub const default_port: u16 = 8085;
/// Default remote SSH connection port.
pub const default_ssh_port: u16 = 22;
/// Default SQLite cache database path on the remote host.
pub const default_db_path = "/volume1/docker/zprobe/zprobe_cache.db";
/// Default output path for service file generation ('-' specifies stdout).
pub const default_output = "-";

/// Deployment CLI subcommands.
pub const Command = enum {
    build,
    service,
    install,
    help,

    /// Parses a command-line subcommand string into a `Command` enum variant.
    pub fn fromString(s: []const u8) ?Command {
        if (std.mem.eql(u8, s, "build")) return .build;
        if (std.mem.eql(u8, s, "service")) return .service;
        if (std.mem.eql(u8, s, "install")) return .install;
        if (std.mem.eql(u8, s, "help") or std.mem.eql(u8, s, "-h") or std.mem.eql(u8, s, "--help")) return .help;
        return null;
    }
};

/// Errors that can occur during deployment preparation, building, or remote execution.
pub const DeployError = error{
    UnknownCommand,
    UnknownArgument,
    MissingHostValue,
    MissingUserValue,
    MissingRemoteDirValue,
    MissingPortValue,
    MissingDbValue,
    MissingOutputValue,
    MissingTargetValue,
    MissingSshPortValue,
    MissingAuthUserValue,
    MissingAuthPassValue,
    InvalidPortNumber,
    InvalidSshPortNumber,
    InvalidTarget,
    BinaryNotFound,
    BuildFailed,
    SyncFailed,
    RemoteExecutionFailed,
    CommandFailed,
};

/// Target architectures supported for cross-compilation and automated deployment.
pub const supported_targets = [_][]const u8{
    "synology-arm64",
    "synology-x86_64",
    "macos-arm64",
    "windows-x86_64",
};

/// Checks whether the provided target name matches a supported release architecture.
pub fn isValidTarget(target: []const u8) bool {
    for (supported_targets) |t| {
        if (std.mem.eql(u8, t, target)) return true;
    }
    return false;
}

/// Structured command-line arguments parsed from process invocation.
pub const ParsedArgs = struct {
    command: Command,
    host: []const u8,
    ssh_port: u16,
    user: ?[]const u8,
    remote_dir: []const u8,
    port: u16,
    db: []const u8,
    output: []const u8,
    target: []const u8,
    auth_user: ?[]const u8,
    auth_pass: ?[]const u8,
};

/// Prints CLI usage and available options to stdout.
pub fn printUsage(io: std.Io) !void {
    var stdout_buf: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stdout(), io, &stdout_buf);
    try writer.interface.writeAll(usage);
    try writer.flush();
}

/// Parsed remote SSH host and optional custom port.
pub const HostAndPort = struct {
    host: []const u8,
    port: ?u16,
};

/// Splits a host string into hostname and optional port (e.g. "admin@nas.local:2222").
pub fn splitHostAndPort(host_str: []const u8) HostAndPort {
    if (std.mem.lastIndexOfScalar(u8, host_str, ':')) |idx| {
        if (idx > 0 and idx + 1 < host_str.len) {
            if (std.fmt.parseInt(u16, host_str[idx + 1 ..], 10)) |p| {
                return .{ .host = host_str[0..idx], .port = p };
            } else |_| {}
        }
    }
    return .{ .host = host_str, .port = null };
}

/// Extracts the username component from a "user@host" string, if present.
pub fn extractUserFromHost(host: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, host, '@')) |idx| {
        if (idx > 0) {
            return host[0..idx];
        }
    }
    return null;
}

/// Validates that HTTP basic auth credentials are provided as a complete pair (or both omitted).
pub fn validateAuth(auth_user: ?[]const u8, auth_pass: ?[]const u8) error{IncompleteAuth}!void {
    const user_set = if (auth_user) |u| u.len > 0 else false;
    const pass_set = if (auth_pass) |p| p.len > 0 else false;
    if (user_set != pass_set) {
        return error.IncompleteAuth;
    }
}

/// Parses command-line arguments into structured `ParsedArgs`.
pub fn parseArgs(args: []const [:0]const u8) !ParsedArgs {
    var result: ParsedArgs = .{
        .command = .help,
        .host = "",
        .ssh_port = default_ssh_port,
        .user = null,
        .remote_dir = default_remote_dir,
        .port = default_port,
        .db = default_db_path,
        .output = default_output,
        .target = default_target,
        .auth_user = null,
        .auth_pass = null,
    };

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (Command.fromString(arg)) |cmd| {
            result.command = cmd;
            continue;
        }

        if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return error.MissingHostValue;
            result.host = args[i];
            continue;
        }

        if (std.mem.eql(u8, arg, "--ssh-port")) {
            i += 1;
            if (i >= args.len) return error.MissingSshPortValue;
            result.ssh_port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidSshPortNumber;
            continue;
        }

        if (std.mem.eql(u8, arg, "--user")) {
            i += 1;
            if (i >= args.len) return error.MissingUserValue;
            result.user = args[i];
            continue;
        }

        if (std.mem.eql(u8, arg, "--remote-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingRemoteDirValue;
            result.remote_dir = args[i];
            continue;
        }

        if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingPortValue;
            result.port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPortNumber;
            continue;
        }

        if (std.mem.eql(u8, arg, "--db")) {
            i += 1;
            if (i >= args.len) return error.MissingDbValue;
            result.db = args[i];
            continue;
        }

        if (std.mem.eql(u8, arg, "--auth-user")) {
            i += 1;
            if (i >= args.len) return error.MissingAuthUserValue;
            result.auth_user = args[i];
            continue;
        }

        if (std.mem.eql(u8, arg, "--auth-pass")) {
            i += 1;
            if (i >= args.len) return error.MissingAuthPassValue;
            result.auth_pass = args[i];
            continue;
        }

        if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingOutputValue;
            result.output = args[i];
            continue;
        }

        if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i >= args.len) return error.MissingTargetValue;
            if (!isValidTarget(args[i])) return error.InvalidTarget;
            result.target = args[i];
            continue;
        }

        return error.UnknownArgument;
    }

    if (result.host.len > 0) {
        const split = splitHostAndPort(result.host);
        result.host = split.host;
        if (split.port) |p| {
            if (result.ssh_port == default_ssh_port) {
                result.ssh_port = p;
            }
        }
    }

    return result;
}

fn runCommand(io: std.Io, argv: []const []const u8) !void {
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

fn writeServiceFile(io: std.Io, allocator: std.mem.Allocator, output_path: []const u8, content: []const u8) !void {
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

fn runBuild(io: std.Io, target: []const u8) !void {
    std.debug.print("[deploy] Building release targets for: {s}\n", .{target});
    const argv = [_][]const u8{ "zig", "build", "release-all" };
    runCommand(io, &argv) catch return error.BuildFailed;
    std.debug.print("[deploy] Build complete.\n", .{});
}

fn runService(
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

fn runInstall(
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

/// Main entrypoint for the `zprobe-deploy` executable.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    const parsed = parseArgs(args) catch |err| {
        std.debug.print("Error: {s}\n\n", .{@errorName(err)});
        printUsage(io) catch {};
        std.process.exit(1);
    };

    const env_auth_user = init.environ_map.get("ZPROBE_AUTH_USER");
    const env_auth_pass = init.environ_map.get("ZPROBE_AUTH_PASS");
    const auth_user = parsed.auth_user orelse env_auth_user;
    const auth_pass = parsed.auth_pass orelse env_auth_pass;

    validateAuth(auth_user, auth_pass) catch {
        std.debug.print("Error: Both auth user and auth password must be provided to enable authentication\n\n", .{});
        printUsage(io) catch {};
        std.process.exit(1);
    };

    switch (parsed.command) {
        .help => try printUsage(io),
        .build => try runBuild(io, parsed.target),
        .service => {
            const service_user = parsed.user orelse {
                std.debug.print("Error: service command requires --user <username>\n\n", .{});
                printUsage(io) catch {};
                std.process.exit(1);
            };
            try runService(io, allocator, service_user, parsed.remote_dir, parsed.port, parsed.db, parsed.output, auth_user, auth_pass);
        },
        .install => {
            if (parsed.host.len == 0) {
                std.debug.print("Error: install requires --host <user@host>\n\n", .{});
                printUsage(io) catch {};
                std.process.exit(1);
            }
            const service_user = parsed.user orelse (extractUserFromHost(parsed.host) orelse {
                std.debug.print("Error: user could not be determined. Please specify --user <username> or provide --host <user@host>\n\n", .{});
                printUsage(io) catch {};
                std.process.exit(1);
            });
            try runInstall(io, allocator, parsed.host, parsed.ssh_port, service_user, parsed.remote_dir, parsed.port, parsed.db, parsed.target, auth_user, auth_pass);
        },
    }
}

test "extractUserFromHost extracts username or returns null" {
    try std.testing.expectEqualStrings("admin", extractUserFromHost("admin@nas.local").?);
    try std.testing.expectEqualStrings("admin", extractUserFromHost("admin@192.168.1.100").?);
    try std.testing.expect(extractUserFromHost("nas.local") == null);
    try std.testing.expect(extractUserFromHost("@nas.local") == null);
}

test "parseArgs parses flags and defaults correctly" {
    const args = [_][:0]const u8{
        "zprobe-deploy",
        "install",
        "--host",
        "admin@nas.local",
        "--user",
        "customuser",
        "--port",
        "9000",
        "--db",
        "/custom/path.db",
        "--remote-dir",
        "/volume1/app",
        "--target",
        "synology-x86_64",
    };

    const parsed = try parseArgs(&args);
    try std.testing.expectEqual(Command.install, parsed.command);
    try std.testing.expectEqualStrings("admin@nas.local", parsed.host);
    try std.testing.expectEqualStrings("customuser", parsed.user.?);
    try std.testing.expectEqual(@as(u16, 9000), parsed.port);
    try std.testing.expectEqualStrings("/custom/path.db", parsed.db);
    try std.testing.expectEqualStrings("/volume1/app", parsed.remote_dir);
    try std.testing.expectEqualStrings("synology-x86_64", parsed.target);
}

test "parseArgs handles missing flag values and invalid numbers" {
    const args_missing_host = [_][:0]const u8{ "zprobe-deploy", "install", "--host" };
    try std.testing.expectError(error.MissingHostValue, parseArgs(&args_missing_host));

    const args_unknown = [_][:0]const u8{ "zprobe-deploy", "--unknown-flag" };
    try std.testing.expectError(error.UnknownArgument, parseArgs(&args_unknown));

    const args_invalid_port = [_][:0]const u8{ "zprobe-deploy", "service", "--port", "invalid" };
    try std.testing.expectError(error.InvalidPortNumber, parseArgs(&args_invalid_port));

    const args_invalid_target = [_][:0]const u8{ "zprobe-deploy", "build", "--target", "invalid-arch" };
    try std.testing.expectError(error.InvalidTarget, parseArgs(&args_invalid_target));
}

test "isValidTarget validates supported architectures" {
    try std.testing.expect(isValidTarget("synology-arm64"));
    try std.testing.expect(isValidTarget("synology-x86_64"));
    try std.testing.expect(isValidTarget("macos-arm64"));
    try std.testing.expect(isValidTarget("windows-x86_64"));
    try std.testing.expect(!isValidTarget("linux-arm64"));
    try std.testing.expect(!isValidTarget(""));
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

test "splitHostAndPort correctly splits host and optional port" {
    const normal = splitHostAndPort("admin@nas.local");
    try std.testing.expectEqualStrings("admin@nas.local", normal.host);
    try std.testing.expect(normal.port == null);

    const with_port = splitHostAndPort("admin@nas.local:2222");
    try std.testing.expectEqualStrings("admin@nas.local", with_port.host);
    try std.testing.expectEqual(@as(u16, 2222), with_port.port.?);

    const host_only_with_port = splitHostAndPort("192.168.1.100:8022");
    try std.testing.expectEqualStrings("192.168.1.100", host_only_with_port.host);
    try std.testing.expectEqual(@as(u16, 8022), host_only_with_port.port.?);
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

test "validateAuth requires both credentials or neither" {
    try validateAuth(null, null);
    try validateAuth("admin", "secret");
    try std.testing.expectError(error.IncompleteAuth, validateAuth("admin", null));
    try std.testing.expectError(error.IncompleteAuth, validateAuth(null, "secret"));
    try std.testing.expectError(error.IncompleteAuth, validateAuth("", "secret"));
    try std.testing.expectError(error.IncompleteAuth, validateAuth("admin", ""));
}
