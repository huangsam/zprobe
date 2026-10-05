//! Deployment automation CLI for cross-compiling, staging, and configuring zprobe services.
//!
//! Provides automated builds, systemd service unit generation, and remote SSH/rsync
//! deployment workflows targeting remote hosts and Synology NAS devices.

const std = @import("std");
pub const options = @import("deploy/options.zig");
pub const pipeline = @import("deploy/pipeline.zig");
pub const service = @import("deploy/service.zig");

// Re-export common types and functions for consumers and tests
pub const Command = options.Command;
pub const DeployError = options.DeployError;
pub const ParsedArgs = options.ParsedArgs;
pub const parseArgs = options.parseArgs;
pub const printUsage = options.printUsage;
pub const isValidTarget = options.isValidTarget;
pub const supported_targets = options.supported_targets;
pub const splitHostAndPort = options.splitHostAndPort;
pub const extractUserFromHost = options.extractUserFromHost;
pub const validateAuth = options.validateAuth;

pub const default_target = options.default_target;
pub const default_exec_path = options.default_exec_path;
pub const default_port = options.default_port;
pub const default_ssh_port = options.default_ssh_port;
pub const default_output = options.default_output;

pub const runBuild = pipeline.runBuild;
pub const runService = pipeline.runService;
pub const runInstall = pipeline.runInstall;
pub const resolveBinaryPath = pipeline.resolveBinaryPath;
pub const generateServiceUnitContent = pipeline.generateServiceUnitContent;
pub const inspectRemoteService = pipeline.inspectRemoteService;
pub const parseRemoteServiceOutput = pipeline.parseRemoteServiceOutput;
pub const RemoteServiceInfo = pipeline.RemoteServiceInfo;

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

    const env_sudo_pass = init.environ_map.get("ZPROBE_SUDO_PASS");
    var loaded_sudo_pass: ?[]const u8 = null;
    defer if (loaded_sudo_pass) |p| allocator.free(p);

    if (parsed.sudo_password) |sp| {
        loaded_sudo_pass = try allocator.dupe(u8, sp);
    } else if (parsed.sudo_password_file) |spf| {
        if (std.Io.Dir.openFile(std.Io.Dir.cwd(), io, spf, .{ .mode = .read_only })) |f| {
            defer std.Io.File.close(f, io);
            var buf: [512]u8 = undefined;
            const n = std.Io.File.readPositionalAll(f, io, &buf, 0) catch 0;
            if (n > 0) {
                loaded_sudo_pass = try allocator.dupe(u8, std.mem.trim(u8, buf[0..n], "\r\n "));
            }
        } else |_| {}
    } else if (env_sudo_pass) |esp| {
        loaded_sudo_pass = try allocator.dupe(u8, esp);
    }

    switch (parsed.command) {
        .help => try printUsage(io),
        .build => try runBuild(io, parsed.target),
        .service => {
            const service_user = parsed.user orelse {
                std.debug.print("Error: service command requires --user <username>\n\n", .{});
                printUsage(io) catch {};
                std.process.exit(1);
            };
            const remote_dir = parsed.remote_dir orelse {
                std.debug.print("Error: service command requires --remote-dir <path>\n\n", .{});
                printUsage(io) catch {};
                std.process.exit(1);
            };
            var allocated_db: ?[]const u8 = null;
            defer if (allocated_db) |d| allocator.free(d);
            const service_db = if (parsed.db) |d| d else blk: {
                allocated_db = try std.fmt.allocPrint(allocator, "{s}/zprobe_cache.db", .{remote_dir});
                break :blk allocated_db.?;
            };
            try runService(
                io,
                allocator,
                service_user,
                remote_dir,
                parsed.getPort(),
                service_db,
                parsed.output,
                auth_user,
                auth_pass,
                parsed.exec_path,
            );
        },
        .install => {
            if (parsed.host.len == 0) {
                std.debug.print("Error: install requires --host <user@host>\n\n", .{});
                printUsage(io) catch {};
                std.process.exit(1);
            }
            try runInstall(
                io,
                allocator,
                parsed.host,
                parsed.ssh_port,
                parsed.user,
                parsed.remote_dir,
                parsed.port,
                parsed.db,
                parsed.exec_path,
                parsed.target,
                auth_user,
                auth_pass,
                loaded_sudo_pass,
            );
        },
    }
}

test {
    _ = options;
    _ = pipeline;
    _ = service;
}
