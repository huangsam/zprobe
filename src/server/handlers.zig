const std = @import("std");
const zprobe = @import("zprobe");
const Db = zprobe.db.Db;
const utils = @import("utils.zig");

const assets = @import("../web/assets.zig");
const index_html = assets.index_html;
const logo_svg = assets.logo_svg;
const lucide_js = assets.lucide_js;
const chart_js = assets.chart_js;
const font_outfit_600 = assets.font_outfit_600;
const font_pj_400 = assets.font_pj_400;
const font_pj_600 = assets.font_pj_600;
const styles_css = assets.styles_css;
const app_js = assets.app_js;

pub fn handleStaticAsset(request: *std.http.Server.Request, base_path: []const u8) !bool {
    if (std.mem.eql(u8, base_path, "/") or std.mem.eql(u8, base_path, "/index.html")) {
        try request.respond(index_html, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html" },
            },
        });
        return true;
    } else if (std.mem.eql(u8, base_path, "/js/lucide.min.js")) {
        try request.respond(lucide_js, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
        return true;
    } else if (std.mem.eql(u8, base_path, "/js/chart.umd.js")) {
        try request.respond(chart_js, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
        return true;
    } else if (std.mem.eql(u8, base_path, "/fonts/outfit-600.woff2")) {
        try request.respond(font_outfit_600, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "font/woff2" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
        return true;
    } else if (std.mem.eql(u8, base_path, "/fonts/plus-jakarta-400.woff2")) {
        try request.respond(font_pj_400, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "font/woff2" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
        return true;
    } else if (std.mem.eql(u8, base_path, "/fonts/plus-jakarta-600.woff2")) {
        try request.respond(font_pj_600, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "font/woff2" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
        return true;
    } else if (std.mem.eql(u8, base_path, "/styles.css")) {
        try request.respond(styles_css, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
                .{ .name = "Cache-Control", .value = "public, max-age=86400" },
            },
        });
        return true;
    } else if (std.mem.eql(u8, base_path, "/app.js")) {
        try request.respond(app_js, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
                .{ .name = "Cache-Control", .value = "public, max-age=86400" },
            },
        });
        return true;
    } else if (std.mem.eql(u8, base_path, "/logo.svg")) {
        try request.respond(logo_svg, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "image/svg+xml" },
                .{ .name = "Cache-Control", .value = "public, max-age=86400" },
            },
        });
        return true;
    }
    return false;
}

pub fn handleStats(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    database: *Db,
) !void {
    const stats = blk: {
        database.lockRead(io);
        defer database.unlockRead(io);
        break :blk database.getStatsCached(allocator, io) catch {
            try request.respond("Internal Server Error: Database Query Failed", .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };
    };
    defer stats.deinit(allocator);

    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(allocator);

    {
        var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &json_buf);
        defer json_buf = aw.toArrayList();
        std.json.Stringify.value(stats, .{}, &aw.writer) catch {
            try request.respond("Internal Server Error: JSON Encoding Failed", .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };
    }

    try request.respond(json_buf.items, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });
}

pub fn handleThumbnail(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    database: *Db,
    query_string: []const u8,
) !void {
    var query_path: ?[]const u8 = null;
    var animated: bool = false;

    var query_it = std.mem.splitScalar(u8, query_string, '&');
    while (query_it.next()) |param| {
        if (param.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const key = param[0..eq_idx];
        const val = param[eq_idx + 1 ..];
        if (std.mem.eql(u8, key, "path")) {
            query_path = val;
        } else if (std.mem.eql(u8, key, "animated")) {
            animated = std.mem.eql(u8, val, "1");
        }
    }

    if (query_path == null) {
        try request.respond("Bad Request: missing 'path' parameter", .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    }

    const decoded_path = utils.urlDecode(allocator, query_path.?);
    defer if (decoded_path.ptr != query_path.?.ptr) allocator.free(decoded_path);

    const file_hash: ?[]const u8 = blk: {
        database.lockRead(io);
        defer database.unlockRead(io);
        break :blk database.queryFileHashByPath(allocator, decoded_path) catch null;
    };
    defer if (file_hash) |fh| allocator.free(fh);

    if (file_hash == null or !zprobe.utils.isValidContentHash(file_hash.?)) {
        try request.respond("Not Found: content hash not generated", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    }

    const db_dir = std.fs.path.dirname(database.db_path) orelse ".";
    const artifact_dir = try std.fs.path.join(allocator, &.{ db_dir, if (animated) ".zprobe_animations" else ".zprobe_thumbnails" });
    defer allocator.free(artifact_dir);

    const thumb_abs_path = if (animated)
        zprobe.utils.getAnimatedPreviewPath(allocator, artifact_dir, file_hash.?) catch {
            try request.respond("Not Found: animated preview not generated", .{
                .status = .not_found,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }
    else
        zprobe.utils.getThumbnailPath(allocator, artifact_dir, file_hash.?) catch {
            try request.respond("Not Found: thumbnail not generated", .{
                .status = .not_found,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };
    defer allocator.free(thumb_abs_path);

    const file = std.Io.Dir.openFileAbsolute(io, thumb_abs_path, .{ .mode = .read_only }) catch |err| {
        if (err == error.FileNotFound) {
            database.lockWrite(io);
            defer database.unlockWrite(io);
            if (animated) {
                database.updateHasAnimated(decoded_path, false) catch |db_err| {
                    std.debug.print("Failed to update has_animated cache for '{s}': {}\n", .{ decoded_path, db_err });
                };
            } else {
                database.updateHasThumbnail(decoded_path, false) catch |db_err| {
                    std.debug.print("Failed to update has_thumbnail cache for '{s}': {}\n", .{ decoded_path, db_err });
                };
            }
        }
        const missing_msg = if (animated)
            "Not Found: animated preview not generated"
        else
            "Not Found: thumbnail not generated";
        try request.respond(missing_msg, .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    };
    defer std.Io.File.close(file, io);

    const st = std.Io.File.stat(file, io) catch {
        try request.respond("Internal Server Error: stat failed", .{
            .status = .internal_server_error,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    };

    const buf = try allocator.alloc(u8, st.size);
    defer allocator.free(buf);

    const bytes_read = try std.Io.File.readPositionalAll(file, io, buf, 0);
    if (bytes_read != st.size) {
        try request.respond("Internal Server Error: partial read", .{
            .status = .internal_server_error,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    }

    const content_type: []const u8 = if (animated) "image/gif" else "image/jpeg";
    try request.respond(buf, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = content_type },
            .{ .name = "Cache-Control", .value = "public, max-age=86400" },
        },
    });
}

pub fn handleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    database: *Db,
    query_string: []const u8,
) !void {
    var query_path: ?[]const u8 = null;
    var query_it = std.mem.splitScalar(u8, query_string, '&');
    while (query_it.next()) |param| {
        if (param.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const key = param[0..eq_idx];
        const val = param[eq_idx + 1 ..];
        if (std.mem.eql(u8, key, "path")) {
            query_path = val;
        }
    }

    if (query_path == null) {
        try request.respond("Bad Request: missing 'path' parameter", .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    }

    const decoded_path = utils.urlDecode(allocator, query_path.?);
    defer if (decoded_path.ptr != query_path.?.ptr) allocator.free(decoded_path);

    // Security check: path must exist in database
    const is_valid = blk: {
        database.lockRead(io);
        defer database.unlockRead(io);
        break :blk database.pathExists(decoded_path) catch false;
    };

    if (!is_valid) {
        try request.respond("Forbidden: The requested file path is not indexed. Only files cataloged by the crawler are accessible.", .{
            .status = .forbidden,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    }

    // Open and stream file
    const file = std.Io.Dir.openFileAbsolute(io, decoded_path, .{ .mode = .read_only }) catch |err| {
        std.debug.print("Failed to open file '{s}': {}\n", .{ decoded_path, err });
        try request.respond("Not Found: The file does not exist on the NAS disk. Please run the crawler with --prune to update the catalog.", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    };
    defer std.Io.File.close(file, io);

    const st = std.Io.File.stat(file, io) catch {
        try request.respond("Internal Server Error: Failed to retrieve file size metadata from disk.", .{
            .status = .internal_server_error,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    };

    var range_header: ?[]const u8 = null;
    var header_it = request.iterateHeaders();
    while (header_it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Range")) {
            range_header = header.value;
            break;
        }
    }

    var start: u64 = 0;
    var end: u64 = if (st.size > 0) st.size - 1 else 0;
    var is_range = false;

    if (range_header) |r| {
        if (std.mem.startsWith(u8, r, "bytes=")) {
            const range_str = r["bytes=".len..];
            var parts = std.mem.splitScalar(u8, range_str, '-');
            if (parts.next()) |start_str| {
                if (start_str.len > 0) {
                    start = std.fmt.parseInt(u64, start_str, 10) catch 0;
                    is_range = true;
                }
            }
            if (parts.next()) |end_str| {
                if (end_str.len > 0) {
                    end = std.fmt.parseInt(u64, end_str, 10) catch (if (st.size > 0) st.size - 1 else 0);
                    is_range = true;
                }
            }
        }
    }

    if (st.size > 0 and (start > end or start >= st.size)) {
        var cr_buf: [64]u8 = undefined;
        const cr = std.fmt.bufPrint(&cr_buf, "bytes */{d}", .{st.size}) catch unreachable;
        try request.respond("Range Not Satisfiable", .{
            .status = .range_not_satisfiable,
            .extra_headers = &.{
                .{ .name = "Content-Range", .value = cr },
            },
        });
        return;
    }

    if (end >= st.size) {
        end = if (st.size > 0) st.size - 1 else 0;
    }

    const content_len = if (st.size > 0) end - start + 1 else 0;

    const file_name = std.fs.path.basename(decoded_path);
    const disposition_val = try std.fmt.allocPrint(allocator, "inline; filename=\"{s}\"", .{file_name});
    defer allocator.free(disposition_val);

    var extra_headers: [4]std.http.Header = undefined;
    var extra_count: usize = 0;

    extra_headers[extra_count] = .{ .name = "Content-Type", .value = "application/octet-stream" };
    extra_count += 1;
    extra_headers[extra_count] = .{ .name = "Content-Disposition", .value = disposition_val };
    extra_count += 1;
    extra_headers[extra_count] = .{ .name = "Accept-Ranges", .value = "bytes" };
    extra_count += 1;

    var cr_buf: [128]u8 = undefined;
    if (is_range and st.size > 0) {
        const cr = std.fmt.bufPrint(&cr_buf, "bytes {d}-{d}/{d}", .{ start, end, st.size }) catch unreachable;
        extra_headers[extra_count] = .{ .name = "Content-Range", .value = cr };
        extra_count += 1;
    }

    var stream_buf: [4096]u8 = undefined;
    var stream = try request.respondStreaming(&stream_buf, .{
        .content_length = content_len,
        .respond_options = .{
            .status = if (is_range) .partial_content else .ok,
            .keep_alive = false,
            .extra_headers = extra_headers[0..extra_count],
        },
    });

    var chunk_buf: [65536]u8 = undefined;
    var offset = start;
    var bytes_remaining = content_len;

    while (bytes_remaining > 0) {
        const to_read = @min(bytes_remaining, chunk_buf.len);
        const bytes_read = try std.Io.File.readPositionalAll(file, io, chunk_buf[0..to_read], offset);
        if (bytes_read == 0) break;
        try stream.writer.writeAll(chunk_buf[0..bytes_read]);
        offset += bytes_read;
        bytes_remaining -= bytes_read;
    }
    try stream.end();
}

pub fn handleMedia(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    database: *Db,
    query_string: []const u8,
) !void {
    const params = utils.parseMediaQueryParams(query_string);

    const decoded_search = if (params.search) |s| utils.urlDecode(allocator, s) else null;
    defer if (decoded_search) |ds| {
        if (ds.ptr != params.search.?.ptr) allocator.free(ds);
    };

    const decoded_format = if (params.filter_format) |f| utils.urlDecode(allocator, f) else null;
    defer if (decoded_format) |df| {
        if (df.ptr != params.filter_format.?.ptr) allocator.free(df);
    };

    const decoded_type = if (params.filter_type) |t| utils.urlDecode(allocator, t) else null;
    defer if (decoded_type) |dt| {
        if (dt.ptr != params.filter_type.?.ptr) allocator.free(dt);
    };

    const decoded_date_from = if (params.date_from) |df| utils.urlDecode(allocator, df) else null;
    defer if (decoded_date_from) |ddf| {
        if (ddf.ptr != params.date_from.?.ptr) allocator.free(ddf);
    };

    const decoded_date_to = if (params.date_to) |dt| utils.urlDecode(allocator, dt) else null;
    defer if (decoded_date_to) |ddt| {
        if (ddt.ptr != params.date_to.?.ptr) allocator.free(ddt);
    };

    const decoded_sort = if (params.sort_by) |sb| utils.urlDecode(allocator, sb) else null;
    defer if (decoded_sort) |dsb| {
        if (dsb.ptr != params.sort_by.?.ptr) allocator.free(dsb);
    };

    const decoded_order = if (params.sort_order) |so| utils.urlDecode(allocator, so) else null;
    defer if (decoded_order) |dso| {
        if (dso.ptr != params.sort_order.?.ptr) allocator.free(dso);
    };

    const result = blk: {
        database.lockRead(io);
        defer database.unlockRead(io);
        break :blk database.getRecordsPaged(
            allocator,
            params.limit,
            params.offset,
            decoded_search,
            decoded_format,
            decoded_type,
            decoded_date_from,
            decoded_date_to,
            params.size_min,
            params.size_max,
            decoded_sort,
            decoded_order,
        ) catch {
            try request.respond("Internal Server Error: Database Query Failed", .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };
    };
    defer {
        for (result.records) |r| {
            r.deinit(allocator);
            allocator.free(r.path);
            allocator.free(r.format);
        }
        allocator.free(result.records);
    }

    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(allocator);

    {
        var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &json_buf);
        defer json_buf = aw.toArrayList();
        std.json.Stringify.value(result, .{}, &aw.writer) catch {
            try request.respond("Internal Server Error: JSON Encoding Failed", .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };
    }

    try request.respond(json_buf.items, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });
}

pub fn handleNotes(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    database: *Db,
    query_string: []const u8,
) !void {
    _ = query_string;
    const method = request.head.method;
    if (method != .POST and method != .PUT) {
        try request.respond("Method Not Allowed", .{
            .status = .method_not_allowed,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    }

    var internal_buf: [1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&internal_buf);

    const body_slice = body_reader.allocRemaining(allocator, .limited(65536)) catch {
        try request.respond("Bad Request: Failed to read request body", .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    };
    defer allocator.free(body_slice);

    const NotesPayload = struct {
        hash: []const u8,
        notes: ?[]const u8 = null,
    };

    const parsed = std.json.parseFromSlice(NotesPayload, allocator, body_slice, .{
        .ignore_unknown_fields = true,
    }) catch {
        try request.respond("Bad Request: Invalid JSON payload", .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    };
    defer parsed.deinit();

    const payload = parsed.value;
    if (payload.hash.len == 0) {
        try request.respond("Bad Request: Missing hash field", .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    }

    if (payload.notes) |n| {
        const char_count = std.unicode.utf8CountCodepoints(n) catch {
            try request.respond("Bad Request: Invalid UTF-8 encoding in notes", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };
        if (char_count > 10000) {
            try request.respond("Bad Request: Note content exceeds maximum length of 10,000 characters", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }
    }

    database.lockWrite(io);
    defer database.unlockWrite(io);

    database.updateNotes(payload.hash, payload.notes) catch |err| {
        if (err == error.RecordNotFound) {
            try request.respond("Not Found: Hash not found in database", .{
                .status = .not_found,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }
        try request.respond("Internal Server Error: Failed to update notes", .{
            .status = .internal_server_error,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    };

    try request.respond("{\"status\":\"ok\"}", .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });
}
