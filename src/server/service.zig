const std = @import("std");

/// Configuration parameters for generating a systemd service unit.
pub const ServiceConfig = struct {
    user: []const u8,
    working_dir: []const u8,
    exec_path: []const u8 = "/usr/local/bin/zprobe-server",
    port: u16 = 8080,
    db_path: []const u8,
    auth_user: ?[]const u8 = null,
    auth_pass: ?[]const u8 = null,
};

/// Generates systemd service unit content for zprobe-server.
/// Shared across `zprobe-server --setup-service` and `zprobe-deploy`.
pub fn generateServiceUnit(
    allocator: std.mem.Allocator,
    config: ServiceConfig,
) ![]u8 {
    if (config.auth_user != null and config.auth_pass != null) {
        return std.fmt.allocPrint(
            allocator,
            \\[Unit]
            \\Description=zprobe Insights Server
            \\After=network.target
            \\
            \\[Service]
            \\Type=simple
            \\User={s}
            \\WorkingDirectory={s}
            \\Environment="ZPROBE_AUTH_USER={s}"
            \\Environment="ZPROBE_AUTH_PASS={s}"
            \\ExecStart={s} --port {d} --db {s}
            \\Restart=on-failure
            \\RestartSec=5
            \\
            \\[Install]
            \\WantedBy=multi-user.target
            \\
        ,
            .{
                config.user,
                config.working_dir,
                config.auth_user.?,
                config.auth_pass.?,
                config.exec_path,
                config.port,
                config.db_path,
            },
        );
    }

    return std.fmt.allocPrint(
        allocator,
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
    ,
        .{
            config.user,
            config.working_dir,
            config.exec_path,
            config.port,
            config.db_path,
        },
    );
}

test "generateServiceUnit creates expected unit file without auth" {
    const allocator = std.testing.allocator;
    const unit = try generateServiceUnit(allocator, .{
        .user = "admin",
        .working_dir = "/volume1/docker/zprobe",
        .exec_path = "/usr/local/bin/zprobe-server",
        .port = 8085,
        .db_path = "/volume1/docker/zprobe/zprobe_cache.db",
    });
    defer allocator.free(unit);

    try std.testing.expect(std.mem.indexOf(u8, unit, "Description=zprobe Insights Server") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "User=admin") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "WorkingDirectory=/volume1/docker/zprobe") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "ExecStart=/usr/local/bin/zprobe-server --port 8085 --db /volume1/docker/zprobe/zprobe_cache.db") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Environment=") == null);
}

test "generateServiceUnit injects Environment directives when auth configured" {
    const allocator = std.testing.allocator;
    const unit = try generateServiceUnit(allocator, .{
        .user = "admin",
        .working_dir = "/volume1/docker/zprobe",
        .exec_path = "/opt/zprobe/bin/zprobe-server",
        .port = 9000,
        .db_path = "/volume1/docker/zprobe/cache.db",
        .auth_user = "webadmin",
        .auth_pass = "topsecret",
    });
    defer allocator.free(unit);

    try std.testing.expect(std.mem.indexOf(u8, unit, "Environment=\"ZPROBE_AUTH_USER=webadmin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Environment=\"ZPROBE_AUTH_PASS=topsecret\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "ExecStart=/opt/zprobe/bin/zprobe-server --port 9000 --db /volume1/docker/zprobe/cache.db") != null);
}
