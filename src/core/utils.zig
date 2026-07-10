const std = @import("std");

/// Convert epoch seconds to a civil time string formatted as "YYYY-MM-DD HH:MM:SS".
/// Leverages Howard Hinnant's civil time algorithm (unsigned variant).
pub fn formatEpoch(allocator: std.mem.Allocator, epoch_secs: u64) ![]const u8 {
    const seconds_in_day = 86400;
    const days = epoch_secs / seconds_in_day;
    const seconds_of_day = epoch_secs % seconds_in_day;

    const hour = seconds_of_day / 3600;
    const minute = (seconds_of_day % 3600) / 60;
    const second = seconds_of_day % 60;

    // Civil time algorithm (Howard Hinnant, unsigned variant)
    const z = days + 719468;
    const era = z / 146097;
    const doe = z - era * 146097;
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;

    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year, m, d, hour, minute, second,
    });
}

/// Normalize EXIF-style timestamps ("YYYY:MM:DD HH:MM:SS") to sortable
/// "YYYY-MM-DD HH:MM:SS". Returns a dupe of input when already normalized.
pub fn normalizeDateTime(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len >= 10 and input[4] == ':' and input[7] == ':') {
        var out = try allocator.dupe(u8, input);
        out[4] = '-';
        out[7] = '-';
        return out;
    }
    return try allocator.dupe(u8, input);
}

test "normalizeDateTime converts EXIF colons to dashes" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeDateTime(allocator, "2026:06:27 10:15:30");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("2026-06-27 10:15:30", normalized);

    const already = try normalizeDateTime(allocator, "2024-08-04 21:00:57");
    defer allocator.free(already);
    try std.testing.expectEqualStrings("2024-08-04 21:00:57", already);
}
