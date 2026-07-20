const std = @import("std");
const root = @import("../root.zig");
const db = root.db;

pub fn formatOrientation(orient: u16) []const u8 {
    return switch (orient) {
        1 => "0° (Normal)",
        2 => "Mirrored Horizontal",
        3 => "180°",
        4 => "Mirrored Vertical",
        5 => "Mirrored 90° CCW",
        6 => "90° CW (Vertical)",
        7 => "Mirrored 90° CW",
        8 => "270° CW",
        else => "Unknown",
    };
}

pub fn printMetadataRecord(c_ctx: anytype, db_record: db.DbRecord, fsize: u64) !void {
    c_ctx.stdout_mutex.lockUncancelable(c_ctx.io);
    defer c_ctx.stdout_mutex.unlock(c_ctx.io);

    _ = c_ctx.success_count.fetchAdd(1, .monotonic);

    const interface = &c_ctx.out.interface;

    try interface.print("   {s} ({d} bytes)\n", .{ db_record.path, fsize });
    try interface.print("    Format: {s}\n", .{db_record.format});
    try interface.print("    Dimensions: {d} x {d}\n", .{ db_record.width.?, db_record.height.? });
    if (db_record.orientation) |orient| {
        try interface.print("    Orientation: {s}\n", .{formatOrientation(orient)});
    }
    if (db_record.create_time) |ct| {
        try interface.print("    Captured: {s}\n", .{ct});
    }
    if (db_record.camera_make) |make| {
        try interface.print("    Camera Make: {s}\n", .{make});
    }
    if (db_record.camera_model) |model| {
        try interface.print("    Camera Model: {s}\n", .{model});
    }
    if (db_record.gps_latitude) |lat| {
        if (db_record.gps_longitude) |lon| {
            const lat_ref: u8 = if (lat >= 0) 'N' else 'S';
            const lon_ref: u8 = if (lon >= 0) 'E' else 'W';
            try interface.print("    GPS: {d:.4}° {c}, {d:.4}° {c}\n", .{
                @abs(lat), lat_ref, @abs(lon), lon_ref,
            });
        }
    }
    if (db_record.duration_sec) |dur| {
        try interface.print("    Duration: {d:.2} sec\n", .{dur});
    }
    try interface.print("\n", .{});
}
