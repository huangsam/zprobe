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
pub const default_remote_dir = options.default_remote_dir;
pub const default_port = options.default_port;
pub const default_ssh_port = options.default_ssh_port;
pub const default_db_path = options.default_db_path;
pub const default_output = options.default_output;

pub const runBuild = pipeline.runBuild;
pub const runService = pipeline.runService;
pub const runInstall = pipeline.runInstall;
pub const resolveBinaryPath = pipeline.resolveBinaryPath;
pub const generateServiceUnitContent = pipeline.generateServiceUnitContent;

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

test {
    _ = options;
    _ = pipeline;
    _ = service;
}
