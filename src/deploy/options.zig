//! Command-line options and argument parsing for zprobe-deploy.

const std = @import("std");

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
    if (std.mem.findScalarLast(u8, host_str, ':')) |idx| {
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
    if (std.mem.findScalar(u8, host, '@')) |idx| {
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

test "validateAuth requires both credentials or neither" {
    try validateAuth(null, null);
    try validateAuth("admin", "secret");
    try std.testing.expectError(error.IncompleteAuth, validateAuth("admin", null));
    try std.testing.expectError(error.IncompleteAuth, validateAuth(null, "secret"));
    try std.testing.expectError(error.IncompleteAuth, validateAuth("", "secret"));
    try std.testing.expectError(error.IncompleteAuth, validateAuth("admin", ""));
}
