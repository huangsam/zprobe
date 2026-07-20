const std = @import("std");

pub fn urlDecode(allocator: std.mem.Allocator, input: []const u8) []const u8 {
    var result = allocator.alloc(u8, input.len) catch return input;
    var out_idx: usize = 0;
    var in_idx: usize = 0;
    while (in_idx < input.len) {
        const ch = input[in_idx];
        if (ch == '+') {
            result[out_idx] = ' ';
            out_idx += 1;
            in_idx += 1;
        } else if (ch == '%' and in_idx + 2 < input.len) {
            const hex = input[in_idx + 1 .. in_idx + 3];
            const val = std.fmt.parseInt(u8, hex, 16) catch {
                result[out_idx] = '%';
                out_idx += 1;
                in_idx += 1;
                continue;
            };
            result[out_idx] = val;
            out_idx += 1;
            in_idx += 3;
        } else {
            result[out_idx] = ch;
            out_idx += 1;
            in_idx += 1;
        }
    }
    if (allocator.resize(result, out_idx)) {
        return result[0..out_idx];
    } else {
        const new_res = allocator.dupe(u8, result[0..out_idx]) catch {
            allocator.free(result);
            return input;
        };
        allocator.free(result);
        return new_res;
    }
}

pub const MediaQueryParams = struct {
    limit: u32 = 25,
    offset: u32 = 0,
    search: ?[]const u8 = null,
    filter_format: ?[]const u8 = null,
    filter_type: ?[]const u8 = null,
    date_from: ?[]const u8 = null,
    date_to: ?[]const u8 = null,
    size_min: ?u64 = null,
    size_max: ?u64 = null,
    sort_by: ?[]const u8 = null,
    sort_order: ?[]const u8 = null,
};

pub fn parseMediaQueryParams(query_string: []const u8) MediaQueryParams {
    var params = MediaQueryParams{};
    var query_it = std.mem.splitScalar(u8, query_string, '&');
    while (query_it.next()) |param| {
        if (param.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const key = param[0..eq_idx];
        const val = param[eq_idx + 1 ..];

        if (std.mem.eql(u8, key, "limit")) {
            params.limit = std.fmt.parseInt(u32, val, 10) catch 25;
        } else if (std.mem.eql(u8, key, "offset")) {
            params.offset = std.fmt.parseInt(u32, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "search")) {
            params.search = val;
        } else if (std.mem.eql(u8, key, "format")) {
            params.filter_format = val;
        } else if (std.mem.eql(u8, key, "type")) {
            params.filter_type = val;
        } else if (std.mem.eql(u8, key, "date_from")) {
            params.date_from = val;
        } else if (std.mem.eql(u8, key, "date_to")) {
            params.date_to = val;
        } else if (std.mem.eql(u8, key, "size_min")) {
            params.size_min = std.fmt.parseInt(u64, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "size_max")) {
            params.size_max = std.fmt.parseInt(u64, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "sort")) {
            params.sort_by = val;
        } else if (std.mem.eql(u8, key, "order")) {
            params.sort_order = val;
        }
    }
    params.limit = std.math.clamp(params.limit, 1, 100);
    return params;
}

test "urlDecode parsing and fallback" {
    const allocator = std.testing.allocator;

    const decoded = urlDecode(allocator, "hello+world%20test");
    defer if (decoded.ptr != "hello+world%20test".ptr) allocator.free(decoded);

    try std.testing.expectEqualStrings("hello world test", decoded);

    const empty = urlDecode(allocator, "");
    defer if (empty.ptr != "".ptr) allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const invalid = urlDecode(allocator, "%xy");
    defer if (invalid.ptr != "%xy".ptr) allocator.free(invalid);
    try std.testing.expectEqualStrings("%xy", invalid);
}

test "parseMediaQueryParams limit clamping and parsing" {
    // 1. Default limit is 25 when limit is absent
    const params_default = parseMediaQueryParams("offset=10");
    try std.testing.expectEqual(@as(u32, 25), params_default.limit);
    try std.testing.expectEqual(@as(u32, 10), params_default.offset);

    // 2. Custom limit is parsed correctly
    const params_custom = parseMediaQueryParams("limit=50&offset=20&search=foo");
    try std.testing.expectEqual(@as(u32, 50), params_custom.limit);
    try std.testing.expectEqual(@as(u32, 20), params_custom.offset);
    try std.testing.expectEqualStrings("foo", params_custom.search.?);

    // 3. Limit is clamped to 100 if higher limit is requested
    const params_high = parseMediaQueryParams("limit=1000");
    try std.testing.expectEqual(@as(u32, 100), params_high.limit);

    // 4. Limit is clamped to 1 if 0 is requested
    const params_zero = parseMediaQueryParams("limit=0");
    try std.testing.expectEqual(@as(u32, 1), params_zero.limit);

    // 5. If limit parsing fails (non-numeric), it defaults to 25 and clamps
    const params_invalid = parseMediaQueryParams("limit=abc");
    try std.testing.expectEqual(@as(u32, 25), params_invalid.limit);

    // 6. Test all other parameters are parsed correctly
    const params_all = parseMediaQueryParams("limit=10&offset=5&search=hello&format=png&type=image&date_from=2023-01-01&date_to=2023-12-31&size_min=100&size_max=2000&sort=name&order=desc");
    try std.testing.expectEqual(@as(u32, 10), params_all.limit);
    try std.testing.expectEqual(@as(u32, 5), params_all.offset);
    try std.testing.expectEqualStrings("hello", params_all.search.?);
    try std.testing.expectEqualStrings("png", params_all.filter_format.?);
    try std.testing.expectEqualStrings("image", params_all.filter_type.?);
    try std.testing.expectEqualStrings("2023-01-01", params_all.date_from.?);
    try std.testing.expectEqualStrings("2023-12-31", params_all.date_to.?);
    try std.testing.expectEqual(@as(u64, 100), params_all.size_min.?);
    try std.testing.expectEqual(@as(u64, 2000), params_all.size_max.?);
    try std.testing.expectEqualStrings("name", params_all.sort_by.?);
    try std.testing.expectEqualStrings("desc", params_all.sort_order.?);
}
