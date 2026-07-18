const std = @import("std");
const Db = @import("../db.zig").Db;
const c = @import("../db.zig").c;
const types = @import("types.zig");

const DbRecord = types.DbRecord;
const CacheResult = types.CacheResult;
const DbStats = types.DbStats;
const PagedResult = types.PagedResult;
const stats_cache_ttl_ns = types.stats_cache_ttl_ns;
const is_image_pred_m = types.is_image_pred_m;
const is_video_pred_m = types.is_video_pred_m;

pub fn invalidateStatsCache(self: *Db, io: std.Io) void {
    self.stats_mutex.lockUncancelable(io);
    defer self.stats_mutex.unlock(io);
    self.stats_cache = null;
    self.stats_cache_expires_ns = 0;
    self.stats_cache_arena.deinit();
    self.stats_cache_arena = std.heap.ArenaAllocator.init(self.allocator);
}

fn cloneStats(allocator: std.mem.Allocator, src: DbStats) !DbStats {
    var image_formats: std.ArrayList(DbStats.FormatCount) = .empty;
    errdefer {
        for (image_formats.items) |item| allocator.free(item.format);
        image_formats.deinit(allocator);
    }
    for (src.image_formats) |item| {
        try image_formats.append(allocator, .{
            .format = try allocator.dupe(u8, item.format),
            .count = item.count,
        });
    }

    var video_formats: std.ArrayList(DbStats.FormatCount) = .empty;
    errdefer {
        for (video_formats.items) |item| allocator.free(item.format);
        video_formats.deinit(allocator);
    }
    for (src.video_formats) |item| {
        try video_formats.append(allocator, .{
            .format = try allocator.dupe(u8, item.format),
            .count = item.count,
        });
    }

    var cameras: std.ArrayList(DbStats.CameraCount) = .empty;
    errdefer {
        for (cameras.items) |item| {
            allocator.free(item.make);
            allocator.free(item.model);
        }
        cameras.deinit(allocator);
    }
    for (src.cameras) |item| {
        try cameras.append(allocator, .{
            .make = try allocator.dupe(u8, item.make),
            .model = try allocator.dupe(u8, item.model),
            .count = item.count,
        });
    }

    return DbStats{
        .total_files = src.total_files,
        .total_size = src.total_size,
        .num_images = src.num_images,
        .num_videos = src.num_videos,
        .image_formats = try image_formats.toOwnedSlice(allocator),
        .video_formats = try video_formats.toOwnedSlice(allocator),
        .cameras = try cameras.toOwnedSlice(allocator),
        .image_sizes = src.image_sizes,
        .video_sizes = src.video_sizes,
        .video_durations = src.video_durations,
    };
}

/// Return cached stats when fresh, otherwise refresh the cache.
pub fn getStatsCached(self: *Db, allocator: std.mem.Allocator, io: std.Io) !DbStats {
    self.stats_mutex.lockUncancelable(io);
    defer self.stats_mutex.unlock(io);

    const now = std.Io.Clock.real.now(io).nanoseconds;
    if (self.stats_cache) |cached| {
        if (now < self.stats_cache_expires_ns) {
            return try cloneStats(allocator, cached);
        }
    }

    self.stats_cache = null;
    self.stats_cache_arena.deinit();
    self.stats_cache_arena = std.heap.ArenaAllocator.init(self.allocator);
    const cache_alloc = self.stats_cache_arena.allocator();

    const fresh = try self.getStats(cache_alloc);
    self.stats_cache = fresh;
    self.stats_cache_expires_ns = now + stats_cache_ttl_ns;

    return try cloneStats(allocator, fresh);
}

fn fillMetadataFields(
    allocator: std.mem.Allocator,
    record: *DbRecord,
    stmt: ?*c.sqlite3_stmt,
    base_idx: c_int,
    has_hash: bool,
) !void {
    if (c.sqlite3_column_type(stmt, base_idx + 0) != c.SQLITE_NULL) {
        record.width = @intCast(c.sqlite3_column_int(stmt, base_idx + 0));
    }
    if (c.sqlite3_column_type(stmt, base_idx + 1) != c.SQLITE_NULL) {
        record.height = @intCast(c.sqlite3_column_int(stmt, base_idx + 1));
    }
    if (c.sqlite3_column_type(stmt, base_idx + 2) != c.SQLITE_NULL) {
        record.orientation = @intCast(c.sqlite3_column_int(stmt, base_idx + 2));
    }
    if (c.sqlite3_column_type(stmt, base_idx + 3) != c.SQLITE_NULL) {
        const raw = c.sqlite3_column_text(stmt, base_idx + 3);
        const len = c.sqlite3_column_bytes(stmt, base_idx + 3);
        record.create_time = try allocator.dupe(u8, raw[0..@intCast(len)]);
    }
    errdefer {
        if (record.create_time) |ct| {
            allocator.free(ct);
            record.create_time = null;
        }
    }
    if (c.sqlite3_column_type(stmt, base_idx + 4) != c.SQLITE_NULL) {
        const raw = c.sqlite3_column_text(stmt, base_idx + 4);
        const len = c.sqlite3_column_bytes(stmt, base_idx + 4);
        record.camera_make = try allocator.dupe(u8, raw[0..@intCast(len)]);
    }
    errdefer {
        if (record.camera_make) |cm| {
            allocator.free(cm);
            record.camera_make = null;
        }
    }
    if (c.sqlite3_column_type(stmt, base_idx + 5) != c.SQLITE_NULL) {
        const raw = c.sqlite3_column_text(stmt, base_idx + 5);
        const len = c.sqlite3_column_bytes(stmt, base_idx + 5);
        record.camera_model = try allocator.dupe(u8, raw[0..@intCast(len)]);
    }
    errdefer {
        if (record.camera_model) |cm| {
            allocator.free(cm);
            record.camera_model = null;
        }
    }
    if (c.sqlite3_column_type(stmt, base_idx + 6) != c.SQLITE_NULL) {
        record.gps_latitude = c.sqlite3_column_double(stmt, base_idx + 6);
    }
    if (c.sqlite3_column_type(stmt, base_idx + 7) != c.SQLITE_NULL) {
        record.gps_longitude = c.sqlite3_column_double(stmt, base_idx + 7);
    }
    if (c.sqlite3_column_type(stmt, base_idx + 8) != c.SQLITE_NULL) {
        record.duration_sec = c.sqlite3_column_double(stmt, base_idx + 8);
    }
    if (c.sqlite3_column_type(stmt, base_idx + 9) != c.SQLITE_NULL) {
        record.has_thumbnail = c.sqlite3_column_int(stmt, base_idx + 9) != 0;
    }
    if (c.sqlite3_column_type(stmt, base_idx + 10) != c.SQLITE_NULL) {
        record.has_animated = c.sqlite3_column_int(stmt, base_idx + 10) != 0;
    }
    if (has_hash and c.sqlite3_column_type(stmt, base_idx + 11) != c.SQLITE_NULL) {
        const raw = c.sqlite3_column_text(stmt, base_idx + 11);
        const len = c.sqlite3_column_bytes(stmt, base_idx + 11);
        record.file_hash = try allocator.dupe(u8, raw[0..@intCast(len)]);
    }
}

/// Check if a cached media record matching size and modification time exists.
pub fn queryCache(
    self: *Db,
    allocator: std.mem.Allocator,
    path: []const u8,
    size: u64,
    mtime: i64,
) !CacheResult {
    if (self.handle == null) return .{ .hit = false };

    const query_sql =
        \\SELECT p.size, p.mtime, m.format, m.width, m.height, m.orientation, m.create_time, m.camera_make, m.camera_model, m.gps_latitude, m.gps_longitude, m.duration_sec, m.has_thumbnail, m.has_animated, m.file_hash
        \\FROM media_paths p
        \\JOIN media_metadata m ON p.metadata_id = m.id
        \\WHERE p.path = ?;
    ;
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, query_sql, -1, &stmt, null) != c.SQLITE_OK) {
        return .{ .hit = false };
    }
    defer _ = c.sqlite3_finalize(stmt);

    if (c.sqlite3_bind_text(stmt, 1, path.ptr, @intCast(path.len), null) != c.SQLITE_OK) {
        return .{ .hit = false };
    }

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const db_size = c.sqlite3_column_int64(stmt, 0);
        const db_mtime = c.sqlite3_column_int64(stmt, 1);

        if (db_size == @as(i64, @intCast(size)) and db_mtime == mtime) {
            var json_out = DbRecord{
                .path = path,
                .size = size,
                .format = undefined,
            };
            errdefer json_out.deinit(allocator);

            const fmt_raw = c.sqlite3_column_text(stmt, 2);
            if (fmt_raw) |raw| {
                const fmt_len = c.sqlite3_column_bytes(stmt, 2);
                json_out.format = try allocator.dupe(u8, raw[0..@intCast(fmt_len)]);
            } else {
                json_out.format = try allocator.dupe(u8, "unknown");
            }
            errdefer allocator.free(json_out.format);

            try fillMetadataFields(allocator, &json_out, stmt, 3, true);

            return .{ .hit = true, .json_out = json_out };
        }
    }

    return .{ .hit = false };
}

/// Retrieve a media metadata and path record by its content hash.
pub fn queryMetadataByHash(
    self: *Db,
    allocator: std.mem.Allocator,
    path: []const u8,
    file_hash: []const u8,
) !?DbRecord {
    if (self.handle == null) return error.DatabaseNotOpen;
    const sql =
        \\SELECT format, width, height, orientation, create_time, camera_make, camera_model, gps_latitude, gps_longitude, duration_sec, has_thumbnail, has_animated
        \\FROM media_metadata
        \\WHERE file_hash = ?;
    ;
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.DatabasePrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_text(stmt, 1, file_hash.ptr, @intCast(file_hash.len), null);

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        var json_out = DbRecord{
            .path = path,
            .size = 0,
            .format = undefined,
            .file_hash = try allocator.dupe(u8, file_hash),
        };
        errdefer json_out.deinit(allocator);

        const fmt_raw = c.sqlite3_column_text(stmt, 0);
        if (fmt_raw) |raw| {
            const fmt_len = c.sqlite3_column_bytes(stmt, 0);
            json_out.format = try allocator.dupe(u8, raw[0..@intCast(fmt_len)]);
        } else {
            json_out.format = try allocator.dupe(u8, "unknown");
        }
        errdefer allocator.free(json_out.format);

        try fillMetadataFields(allocator, &json_out, stmt, 1, false);

        return json_out;
    }

    return null;
}

/// Insert or replace a media catalog entry.
pub fn insertMedia(
    self: *Db,
    io: std.Io,
    json_out: *const DbRecord,
    mtime: i64,
) !void {
    if (self.handle == null) return error.DatabaseNotOpen;

    // 1. Generate fallback file hash signature if not provided
    var hash_buf: [256]u8 = undefined;
    const file_hash = if (json_out.file_hash) |fh| fh else try std.fmt.bufPrint(&hash_buf, "{d}_{d}_{s}_{d}_{d}", .{
        json_out.size,
        mtime,
        json_out.format,
        json_out.width orelse 0,
        json_out.height orelse 0,
    });

    // 2. Prepare/Insert into media_metadata
    const insert_meta_sql =
        \\INSERT INTO media_metadata (file_hash, format, width, height, orientation, create_time, camera_make, camera_model, gps_latitude, gps_longitude, duration_sec, has_thumbnail, has_animated)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    ;
    var insert_meta_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, insert_meta_sql, -1, &insert_meta_stmt, null) != c.SQLITE_OK) {
        return error.DatabasePrepareError;
    }
    defer _ = c.sqlite3_finalize(insert_meta_stmt);

    _ = c.sqlite3_bind_text(insert_meta_stmt, 1, file_hash.ptr, @intCast(file_hash.len), null);
    _ = c.sqlite3_bind_text(insert_meta_stmt, 2, json_out.format.ptr, @intCast(json_out.format.len), null);

    if (json_out.width) |w| {
        _ = c.sqlite3_bind_int(insert_meta_stmt, 3, @intCast(w));
    } else {
        _ = c.sqlite3_bind_null(insert_meta_stmt, 3);
    }
    if (json_out.height) |h| {
        _ = c.sqlite3_bind_int(insert_meta_stmt, 4, @intCast(h));
    } else {
        _ = c.sqlite3_bind_null(insert_meta_stmt, 4);
    }
    if (json_out.orientation) |o| {
        _ = c.sqlite3_bind_int(insert_meta_stmt, 5, @intCast(o));
    } else {
        _ = c.sqlite3_bind_null(insert_meta_stmt, 5);
    }
    if (json_out.create_time) |ct| {
        _ = c.sqlite3_bind_text(insert_meta_stmt, 6, ct.ptr, @intCast(ct.len), null);
    } else {
        _ = c.sqlite3_bind_null(insert_meta_stmt, 6);
    }
    if (json_out.camera_make) |cm| {
        _ = c.sqlite3_bind_text(insert_meta_stmt, 7, cm.ptr, @intCast(cm.len), null);
    } else {
        _ = c.sqlite3_bind_null(insert_meta_stmt, 7);
    }
    if (json_out.camera_model) |cm| {
        _ = c.sqlite3_bind_text(insert_meta_stmt, 8, cm.ptr, @intCast(cm.len), null);
    } else {
        _ = c.sqlite3_bind_null(insert_meta_stmt, 8);
    }
    if (json_out.gps_latitude) |lat| {
        _ = c.sqlite3_bind_double(insert_meta_stmt, 9, lat);
    } else {
        _ = c.sqlite3_bind_null(insert_meta_stmt, 9);
    }
    if (json_out.gps_longitude) |lon| {
        _ = c.sqlite3_bind_double(insert_meta_stmt, 10, lon);
    } else {
        _ = c.sqlite3_bind_null(insert_meta_stmt, 10);
    }
    if (json_out.duration_sec) |dur| {
        _ = c.sqlite3_bind_double(insert_meta_stmt, 11, dur);
    } else {
        _ = c.sqlite3_bind_null(insert_meta_stmt, 11);
    }
    _ = c.sqlite3_bind_int(insert_meta_stmt, 12, if (json_out.has_thumbnail) 1 else 0);
    _ = c.sqlite3_bind_int(insert_meta_stmt, 13, if (json_out.has_animated) 1 else 0);

    var metadata_id: i64 = 0;
    const step_rc = c.sqlite3_step(insert_meta_stmt);
    if (step_rc == c.SQLITE_DONE) {
        metadata_id = c.sqlite3_last_insert_rowid(self.handle);
    } else if (step_rc == c.SQLITE_CONSTRAINT or step_rc == c.SQLITE_CONSTRAINT_UNIQUE) {
        // Hash collision or exists. Retrieve its metadata_id
        const select_id_sql = "SELECT id FROM media_metadata WHERE file_hash = ?;";
        var select_id_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, select_id_sql, -1, &select_id_stmt, null) != c.SQLITE_OK) {
            return error.DatabasePrepareError;
        }
        defer _ = c.sqlite3_finalize(select_id_stmt);
        _ = c.sqlite3_bind_text(select_id_stmt, 1, file_hash.ptr, @intCast(file_hash.len), null);
        if (c.sqlite3_step(select_id_stmt) == c.SQLITE_ROW) {
            metadata_id = c.sqlite3_column_int64(select_id_stmt, 0);
        } else {
            return error.DatabaseExecuteError;
        }

        // Persist artifact-presence flags on the existing metadata row so that
        // thumbnail/preview back-fills (--rebuild-thumbnails, --animated-previews)
        // are recorded even when the content hash already exists. MAX() only ever
        // promotes 0→1: a later --no-thumbnails re-scan of a duplicate can never
        // demote a flag another path already earned on the shared metadata row.
        const update_flags_sql = "UPDATE media_metadata SET has_thumbnail = MAX(has_thumbnail, ?), has_animated = MAX(has_animated, ?) WHERE id = ?;";
        var update_flags_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, update_flags_sql, -1, &update_flags_stmt, null) != c.SQLITE_OK) {
            return error.DatabasePrepareError;
        }
        defer _ = c.sqlite3_finalize(update_flags_stmt);
        _ = c.sqlite3_bind_int(update_flags_stmt, 1, if (json_out.has_thumbnail) 1 else 0);
        _ = c.sqlite3_bind_int(update_flags_stmt, 2, if (json_out.has_animated) 1 else 0);
        _ = c.sqlite3_bind_int64(update_flags_stmt, 3, metadata_id);
        if (c.sqlite3_step(update_flags_stmt) != c.SQLITE_DONE) {
            return error.DatabaseExecuteError;
        }
    } else {
        std.debug.print("Failed to insert media metadata: {s} (code: {d})\n", .{ c.sqlite3_errmsg(self.handle), step_rc });
        return error.DatabaseExecuteError;
    }

    // 3. Insert or replace into media_paths
    const insert_path_sql = "INSERT OR REPLACE INTO media_paths (path, size, mtime, metadata_id) VALUES (?, ?, ?, ?);";
    var insert_path_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, insert_path_sql, -1, &insert_path_stmt, null) != c.SQLITE_OK) {
        return error.DatabasePrepareError;
    }
    defer _ = c.sqlite3_finalize(insert_path_stmt);

    _ = c.sqlite3_bind_text(insert_path_stmt, 1, json_out.path.ptr, @intCast(json_out.path.len), null);
    _ = c.sqlite3_bind_int64(insert_path_stmt, 2, @intCast(json_out.size));
    _ = c.sqlite3_bind_int64(insert_path_stmt, 3, mtime);
    _ = c.sqlite3_bind_int64(insert_path_stmt, 4, metadata_id);

    const path_step_rc = c.sqlite3_step(insert_path_stmt);
    if (path_step_rc != c.SQLITE_DONE) {
        std.debug.print("Failed to insert media path: {s} (code: {d})\n", .{ c.sqlite3_errmsg(self.handle), path_step_rc });
        return error.DatabaseExecuteError;
    }

    self.invalidateStatsCache(io);
}

/// Look up media_metadata.file_hash for a physical path. Returns null if the path
/// is unknown or the hash column is NULL. Caller owns the returned slice.
pub fn queryFileHashByPath(self: *Db, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (self.handle == null) return error.DatabaseNotOpen;
    const sql =
        \\SELECT m.file_hash
        \\FROM media_paths p
        \\JOIN media_metadata m ON p.metadata_id = m.id
        \\WHERE p.path = ?;
    ;
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.DatabasePrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    if (c.sqlite3_bind_text(stmt, 1, path.ptr, @intCast(path.len), null) != c.SQLITE_OK) {
        return error.DatabaseBindError;
    }

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) return null;
        const raw = c.sqlite3_column_text(stmt, 0);
        const len = c.sqlite3_column_bytes(stmt, 0);
        return try allocator.dupe(u8, raw[0..@intCast(len)]);
    }
    return null;
}

/// Update the has_thumbnail flag for a given media record.
pub fn updateHasThumbnail(self: *Db, path: []const u8, has_thumbnail: bool) !void {
    if (self.handle == null) return error.DatabaseNotOpen;
    const sql = "UPDATE media_metadata SET has_thumbnail = ? WHERE id = (SELECT metadata_id FROM media_paths WHERE path = ?);";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.DatabasePrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int(stmt, 1, if (has_thumbnail) 1 else 0);
    _ = c.sqlite3_bind_text(stmt, 2, path.ptr, @intCast(path.len), null);

    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) {
        return error.DatabaseExecuteError;
    }
}

/// Update the has_animated flag for a given media record.
pub fn updateHasAnimated(self: *Db, path: []const u8, has_animated: bool) !void {
    if (self.handle == null) return error.DatabaseNotOpen;
    const sql = "UPDATE media_metadata SET has_animated = ? WHERE id = (SELECT metadata_id FROM media_paths WHERE path = ?);";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.DatabasePrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int(stmt, 1, if (has_animated) 1 else 0);
    _ = c.sqlite3_bind_text(stmt, 2, path.ptr, @intCast(path.len), null);

    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) {
        return error.DatabaseExecuteError;
    }
}

/// Delete a path from the database (triggers will clean up associated metadata).
pub fn deletePath(self: *Db, io: std.Io, path: []const u8) !void {
    if (self.handle == null) return error.DatabaseNotOpen;
    const sql = "DELETE FROM media_paths WHERE path = ?;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.DatabasePrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_text(stmt, 1, path.ptr, @intCast(path.len), null);

    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) {
        return error.DatabaseExecuteError;
    }
    self.invalidateStatsCache(io);
}

/// Prune any cache entries starting with one of target_dirs that are not present in active_paths.
/// Deletes are batched using a single re-used prepared statement under the caller's transaction,
/// with a single stats-cache invalidation at the end.
pub fn pruneStalePaths(self: *Db, io: std.Io, target_dirs: [][]const u8, active_paths: *const std.StringHashMap(void)) !u32 {
    if (self.handle == null) return error.DatabaseNotOpen;

    const select_sql = "SELECT path FROM media_paths;";
    var select_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, select_sql, -1, &select_stmt, null) != c.SQLITE_OK) {
        return error.DatabasePrepareError;
    }
    defer _ = c.sqlite3_finalize(select_stmt);

    var to_delete: std.ArrayList([]const u8) = .empty;
    defer {
        for (to_delete.items) |p| self.allocator.free(p);
        to_delete.deinit(self.allocator);
    }

    while (c.sqlite3_step(select_stmt) == c.SQLITE_ROW) {
        const raw_path = c.sqlite3_column_text(select_stmt, 0);
        const len = c.sqlite3_column_bytes(select_stmt, 0);
        const path = raw_path[0..@intCast(len)];

        // Check if this path resides in one of the scanned directories
        var in_scanned_dir = false;
        for (target_dirs) |dir| {
            if (std.mem.startsWith(u8, path, dir)) {
                if (dir.len > 0 and (dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\')) {
                    in_scanned_dir = true;
                    break;
                } else if (path.len == dir.len or path[dir.len] == '/' or path[dir.len] == '\\') {
                    in_scanned_dir = true;
                    break;
                }
            }
        }

        if (in_scanned_dir) {
            if (!active_paths.contains(path)) {
                const dup = try self.allocator.dupe(u8, path);
                try to_delete.append(self.allocator, dup);
            }
        }
    }

    if (to_delete.items.len == 0) return 0;

    // Prepare a single DELETE statement, reuse it per path, and invalidate
    // the stats cache once at the end rather than once per deletePath() call.
    const delete_sql = "DELETE FROM media_paths WHERE path = ?;";
    var delete_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, delete_sql, -1, &delete_stmt, null) != c.SQLITE_OK) {
        return error.DatabasePrepareError;
    }
    defer _ = c.sqlite3_finalize(delete_stmt);

    var pruned_count: u32 = 0;
    for (to_delete.items) |p| {
        _ = c.sqlite3_reset(delete_stmt);
        _ = c.sqlite3_bind_text(delete_stmt, 1, p.ptr, @intCast(p.len), null);
        const rc = c.sqlite3_step(delete_stmt);
        if (rc != c.SQLITE_DONE) {
            std.debug.print("Warning: failed to prune stale path '{s}' (code: {d})\n", .{ p, rc });
            continue;
        }
        pruned_count += 1;
    }

    if (pruned_count > 0) self.invalidateStatsCache(io);

    return pruned_count;
}

pub fn getAllRecords(self: *Db, allocator: std.mem.Allocator) ![]DbRecord {
    if (self.handle == null) return error.DatabaseNotOpen;

    const select_sql =
        \\SELECT p.path, p.size, m.format, m.width, m.height, m.orientation, m.create_time, m.camera_make, m.camera_model, m.gps_latitude, m.gps_longitude, m.duration_sec, m.has_thumbnail, m.has_animated, m.file_hash
        \\FROM media_paths p
        \\JOIN media_metadata m ON p.metadata_id = m.id;
    ;
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, select_sql, -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("Failed to prepare select query: {s}\n", .{c.sqlite3_errmsg(self.handle)});
        return error.DatabasePrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    var list: std.ArrayList(DbRecord) = .empty;
    errdefer {
        for (list.items) |r| {
            r.deinit(allocator);
            allocator.free(r.path);
            allocator.free(r.format);
        }
        list.deinit(allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        var record = DbRecord{
            .path = undefined,
            .size = undefined,
            .format = undefined,
        };
        errdefer record.deinit(allocator);

        const path_raw = c.sqlite3_column_text(stmt, 0);
        const path_len = c.sqlite3_column_bytes(stmt, 0);
        record.path = try allocator.dupe(u8, path_raw[0..@intCast(path_len)]);
        errdefer allocator.free(record.path);

        record.size = @intCast(c.sqlite3_column_int64(stmt, 1));

        const fmt_raw = c.sqlite3_column_text(stmt, 2);
        if (fmt_raw) |raw| {
            const fmt_len = c.sqlite3_column_bytes(stmt, 2);
            record.format = try allocator.dupe(u8, raw[0..@intCast(fmt_len)]);
        } else {
            record.format = try allocator.dupe(u8, "unknown");
        }
        errdefer allocator.free(record.format);

        try fillMetadataFields(allocator, &record, stmt, 3, true);

        try list.append(allocator, record);
    }

    return try list.toOwnedSlice(allocator);
}

/// Helper to free all records returned by getAllRecords.
pub fn freeAllRecords(self: *Db, records: []DbRecord, allocator: std.mem.Allocator) void {
    _ = self;
    for (records) |r| {
        r.deinit(allocator);
        allocator.free(r.path);
        allocator.free(r.format);
    }
    allocator.free(records);
}

/// Retrieve aggregated statistics for the charts and metrics cards.
pub fn getStats(self: *Db, allocator: std.mem.Allocator) !DbStats {
    if (self.handle == null) return error.DatabaseNotOpen;

    // 1. Overall counts and all tier distributions in a single table scan.
    var total_files: u32 = 0;
    var total_size: u64 = 0;
    var num_images: u32 = 0;
    var num_videos: u32 = 0;
    var img_sizes = DbStats.SizeTiers{ .tier1 = 0, .tier2 = 0, .tier3 = 0, .tier4 = 0, .tier5 = 0 };
    var vid_sizes = DbStats.SizeTiers{ .tier1 = 0, .tier2 = 0, .tier3 = 0, .tier4 = 0, .tier5 = 0 };
    var vid_durations = DbStats.DurationTiers{ .tier1 = 0, .tier2 = 0, .tier3 = 0, .tier4 = 0, .tier5 = 0 };

    const overall_sql =
        "SELECT " ++
        "COUNT(p.path), " ++
        "COALESCE(SUM(p.size), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_image_pred_m ++ " THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_video_pred_m ++ " THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_image_pred_m ++ " AND p.size < 1048576 THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_image_pred_m ++ " AND p.size >= 1048576 AND p.size < 5242880 THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_image_pred_m ++ " AND p.size >= 5242880 AND p.size < 10485760 THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_image_pred_m ++ " AND p.size >= 10485760 AND p.size < 26214400 THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_image_pred_m ++ " AND p.size >= 26214400 THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_video_pred_m ++ " AND p.size < 10485760 THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_video_pred_m ++ " AND p.size >= 10485760 AND p.size < 104857600 THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_video_pred_m ++ " AND p.size >= 104857600 AND p.size < 524288000 THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_video_pred_m ++ " AND p.size >= 524288000 AND p.size < 2147483648 THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_video_pred_m ++ " AND p.size >= 2147483648 THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_video_pred_m ++ " AND m.duration_sec < 10 THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_video_pred_m ++ " AND m.duration_sec >= 10 AND m.duration_sec < 60 THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_video_pred_m ++ " AND m.duration_sec >= 60 AND m.duration_sec < 300 THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_video_pred_m ++ " AND m.duration_sec >= 300 AND m.duration_sec < 900 THEN 1 ELSE 0 END), 0), " ++
        "COALESCE(SUM(CASE WHEN " ++ is_video_pred_m ++ " AND m.duration_sec >= 900 THEN 1 ELSE 0 END), 0) " ++
        "FROM media_paths p " ++
        "JOIN media_metadata m ON p.metadata_id = m.id;";
    var overall_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, overall_sql, -1, &overall_stmt, null) == c.SQLITE_OK) {
        defer _ = c.sqlite3_finalize(overall_stmt);
        if (c.sqlite3_step(overall_stmt) == c.SQLITE_ROW) {
            total_files = @intCast(c.sqlite3_column_int(overall_stmt, 0));
            total_size = @intCast(c.sqlite3_column_int64(overall_stmt, 1));
            num_images = @intCast(c.sqlite3_column_int(overall_stmt, 2));
            num_videos = @intCast(c.sqlite3_column_int(overall_stmt, 3));
            img_sizes.tier1 = @intCast(c.sqlite3_column_int(overall_stmt, 4));
            img_sizes.tier2 = @intCast(c.sqlite3_column_int(overall_stmt, 5));
            img_sizes.tier3 = @intCast(c.sqlite3_column_int(overall_stmt, 6));
            img_sizes.tier4 = @intCast(c.sqlite3_column_int(overall_stmt, 7));
            img_sizes.tier5 = @intCast(c.sqlite3_column_int(overall_stmt, 8));
            vid_sizes.tier1 = @intCast(c.sqlite3_column_int(overall_stmt, 9));
            vid_sizes.tier2 = @intCast(c.sqlite3_column_int(overall_stmt, 10));
            vid_sizes.tier3 = @intCast(c.sqlite3_column_int(overall_stmt, 11));
            vid_sizes.tier4 = @intCast(c.sqlite3_column_int(overall_stmt, 12));
            vid_sizes.tier5 = @intCast(c.sqlite3_column_int(overall_stmt, 13));
            vid_durations.tier1 = @intCast(c.sqlite3_column_int(overall_stmt, 14));
            vid_durations.tier2 = @intCast(c.sqlite3_column_int(overall_stmt, 15));
            vid_durations.tier3 = @intCast(c.sqlite3_column_int(overall_stmt, 16));
            vid_durations.tier4 = @intCast(c.sqlite3_column_int(overall_stmt, 17));
            vid_durations.tier5 = @intCast(c.sqlite3_column_int(overall_stmt, 18));
        }
    }

    // 2. Image and video format counts in one round-trip.
    const formats_sql =
        "SELECT 'image' AS kind, COALESCE(m.format, 'unknown') AS format, COUNT(*) " ++
        "FROM media_paths p JOIN media_metadata m ON p.metadata_id = m.id WHERE " ++ is_image_pred_m ++ " GROUP BY m.format " ++
        "UNION ALL " ++
        "SELECT 'video' AS kind, COALESCE(m.format, 'unknown') AS format, COUNT(*) " ++
        "FROM media_paths p JOIN media_metadata m ON p.metadata_id = m.id WHERE " ++ is_video_pred_m ++ " GROUP BY m.format;";
    var img_formats: std.ArrayList(DbStats.FormatCount) = .empty;
    errdefer {
        for (img_formats.items) |item| allocator.free(item.format);
        img_formats.deinit(allocator);
    }
    var vid_formats: std.ArrayList(DbStats.FormatCount) = .empty;
    errdefer {
        for (vid_formats.items) |item| allocator.free(item.format);
        vid_formats.deinit(allocator);
    }
    var formats_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, formats_sql, -1, &formats_stmt, null) == c.SQLITE_OK) {
        defer _ = c.sqlite3_finalize(formats_stmt);
        while (c.sqlite3_step(formats_stmt) == c.SQLITE_ROW) {
            const kind_raw = c.sqlite3_column_text(formats_stmt, 0);
            const kind_len = c.sqlite3_column_bytes(formats_stmt, 0);
            const kind = kind_raw[0..@intCast(kind_len)];
            const raw = c.sqlite3_column_text(formats_stmt, 1);
            const format_name = if (raw) |r| r[0..@intCast(c.sqlite3_column_bytes(formats_stmt, 1))] else "unknown";
            const count = @as(u32, @intCast(c.sqlite3_column_int(formats_stmt, 2)));
            const entry = DbStats.FormatCount{
                .format = try allocator.dupe(u8, format_name),
                .count = count,
            };
            if (std.mem.eql(u8, kind, "image")) {
                try img_formats.append(allocator, entry);
            } else {
                try vid_formats.append(allocator, entry);
            }
        }
    }

    // 3. Cameras (top 5)
    const cameras_sql =
        "SELECT COALESCE(m.camera_make, ''), COALESCE(m.camera_model, ''), COUNT(*) " ++
        "FROM media_paths p JOIN media_metadata m ON p.metadata_id = m.id WHERE " ++ is_image_pred_m ++ " " ++
        "AND (m.camera_make IS NOT NULL OR m.camera_model IS NOT NULL) " ++
        "GROUP BY m.camera_make, m.camera_model " ++
        "ORDER BY COUNT(*) DESC LIMIT 5;";
    var cameras: std.ArrayList(DbStats.CameraCount) = .empty;
    errdefer {
        for (cameras.items) |item| {
            allocator.free(item.make);
            allocator.free(item.model);
        }
        cameras.deinit(allocator);
    }
    var cameras_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, cameras_sql, -1, &cameras_stmt, null) == c.SQLITE_OK) {
        defer _ = c.sqlite3_finalize(cameras_stmt);
        while (c.sqlite3_step(cameras_stmt) == c.SQLITE_ROW) {
            const make_raw = c.sqlite3_column_text(cameras_stmt, 0);
            const make_len = c.sqlite3_column_bytes(cameras_stmt, 0);
            const model_raw = c.sqlite3_column_text(cameras_stmt, 1);
            const model_len = c.sqlite3_column_bytes(cameras_stmt, 1);
            const count = @as(u32, @intCast(c.sqlite3_column_int(cameras_stmt, 2)));
            try cameras.append(allocator, .{
                .make = try allocator.dupe(u8, make_raw[0..@intCast(make_len)]),
                .model = try allocator.dupe(u8, model_raw[0..@intCast(model_len)]),
                .count = count,
            });
        }
    }

    return DbStats{
        .total_files = total_files,
        .total_size = total_size,
        .num_images = num_images,
        .num_videos = num_videos,
        .image_formats = try img_formats.toOwnedSlice(allocator),
        .video_formats = try vid_formats.toOwnedSlice(allocator),
        .cameras = try cameras.toOwnedSlice(allocator),
        .image_sizes = img_sizes,
        .video_sizes = vid_sizes,
        .video_durations = vid_durations,
    };
}

/// SQL expression that normalizes EXIF "YYYY:MM:DD ..." to "YYYY-MM-DD ...".
/// Note: Must match the expression in schema.zig Version 3 migration (idx_metadata_ctime_norm).
const normalized_create_time_expr =
    "REPLACE(SUBSTR(m.create_time, 1, 10), ':', '-') || SUBSTR(m.create_time, 11)";

/// Retrieve a page of filtered, searched, and sorted media catalog entries.
pub fn getRecordsPaged(
    self: *Db,
    allocator: std.mem.Allocator,
    limit: u32,
    offset: u32,
    search: ?[]const u8,
    format_filter: ?[]const u8,
    type_filter: ?[]const u8,
    date_from: ?[]const u8,
    date_to: ?[]const u8,
    size_min: ?u64,
    size_max: ?u64,
    sort_by: ?[]const u8,
    sort_order: ?[]const u8,
) !PagedResult {
    if (self.handle == null) return error.DatabaseNotOpen;

    // Build WHERE clauses dynamically with sequential bind indices
    var query_buf: std.ArrayList(u8) = .empty;
    defer query_buf.deinit(allocator);

    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &query_buf);
    const writer = &aw.writer;

    try writer.writeAll("FROM media_paths p JOIN media_metadata m ON p.metadata_id = m.id WHERE 1=1");

    var next_param: c_int = 1;

    if (search) |_| {
        try writer.print(
            " AND (p.path LIKE ?{d} OR m.camera_make LIKE ?{d} OR m.camera_model LIKE ?{d} OR m.format LIKE ?{d})",
            .{ next_param, next_param, next_param, next_param },
        );
        next_param += 1;
    }
    if (format_filter) |_| {
        try writer.print(" AND m.format = ?{d}", .{next_param});
        next_param += 1;
    }
    if (type_filter) |t| {
        if (std.mem.eql(u8, t, "image")) {
            try writer.writeAll(" AND " ++ is_image_pred_m);
        } else if (std.mem.eql(u8, t, "video")) {
            try writer.writeAll(" AND " ++ is_video_pred_m);
        }
    }
    if (date_from) |_| {
        try writer.print(" AND m.create_time IS NOT NULL AND " ++ normalized_create_time_expr ++ " >= ?{d}", .{next_param});
        next_param += 1;
    }
    if (date_to) |_| {
        try writer.print(" AND m.create_time IS NOT NULL AND " ++ normalized_create_time_expr ++ " <= ?{d}", .{next_param});
        next_param += 1;
    }
    if (size_min) |_| {
        try writer.print(" AND p.size >= ?{d}", .{next_param});
        next_param += 1;
    }
    if (size_max) |_| {
        try writer.print(" AND p.size <= ?{d}", .{next_param});
        next_param += 1;
    }

    const limit_param = next_param;
    next_param += 1;
    const offset_param = next_param;

    query_buf = aw.toArrayList();
    const base_where = try query_buf.toOwnedSlice(allocator);
    defer allocator.free(base_where);

    // Prepare bind values (kept alive until queries complete)
    var search_like: ?[]const u8 = null;
    defer if (search_like) |sl| allocator.free(sl);
    var date_from_bound: ?[]const u8 = null;
    defer if (date_from_bound) |dfb| allocator.free(dfb);
    var date_to_bound: ?[]const u8 = null;
    defer if (date_to_bound) |dtb| allocator.free(dtb);

    if (search) |s| {
        search_like = try std.fmt.allocPrint(allocator, "%{s}%", .{s});
    }
    if (date_from) |df| {
        date_from_bound = try std.fmt.allocPrint(allocator, "{s} 00:00:00", .{df});
    }
    if (date_to) |dt| {
        date_to_bound = try std.fmt.allocPrint(allocator, "{s} 23:59:59", .{dt});
    }

    const bindFilters = struct {
        fn apply(
            stmt: *c.sqlite3_stmt,
            start_idx: c_int,
            s_like: ?[]const u8,
            fmt: ?[]const u8,
            d_from: ?[]const u8,
            d_to: ?[]const u8,
            s_min: ?u64,
            s_max: ?u64,
        ) c_int {
            var idx: c_int = start_idx;
            if (s_like) |sl| {
                _ = c.sqlite3_bind_text(stmt, idx, sl.ptr, @intCast(sl.len), null);
                idx += 1;
            }
            if (fmt) |f| {
                _ = c.sqlite3_bind_text(stmt, idx, f.ptr, @intCast(f.len), null);
                idx += 1;
            }
            if (d_from) |df| {
                _ = c.sqlite3_bind_text(stmt, idx, df.ptr, @intCast(df.len), null);
                idx += 1;
            }
            if (d_to) |dt| {
                _ = c.sqlite3_bind_text(stmt, idx, dt.ptr, @intCast(dt.len), null);
                idx += 1;
            }
            if (s_min) |sm| {
                _ = c.sqlite3_bind_int64(stmt, idx, @intCast(sm));
                idx += 1;
            }
            if (s_max) |sx| {
                _ = c.sqlite3_bind_int64(stmt, idx, @intCast(sx));
                idx += 1;
            }
            return idx;
        }
    }.apply;

    // 1. Fetch count
    var count_buf: std.ArrayList(u8) = .empty;
    defer count_buf.deinit(allocator);
    var count_aw = std.Io.Writer.Allocating.fromArrayList(allocator, &count_buf);
    try count_aw.writer.writeAll("SELECT COUNT(*) ");
    try count_aw.writer.writeAll(base_where);
    try count_aw.writer.writeAll(";");

    count_buf = count_aw.toArrayList();
    const count_sql = try count_buf.toOwnedSlice(allocator);
    defer allocator.free(count_sql);

    var count_stmt_raw: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, count_sql.ptr, @intCast(count_sql.len), &count_stmt_raw, null) != c.SQLITE_OK) {
        std.debug.print("Failed to prepare count query: {s}\n", .{c.sqlite3_errmsg(self.handle)});
        return error.DatabasePrepareError;
    }
    const count_stmt = count_stmt_raw.?;
    defer _ = c.sqlite3_finalize(count_stmt_raw);

    _ = bindFilters(
        count_stmt,
        1,
        search_like,
        format_filter,
        date_from_bound,
        date_to_bound,
        size_min,
        size_max,
    );

    var total: u32 = 0;
    if (c.sqlite3_step(count_stmt) == c.SQLITE_ROW) {
        total = @intCast(c.sqlite3_column_int(count_stmt, 0));
    }

    // 2. Fetch records
    var select_buf: std.ArrayList(u8) = .empty;
    defer select_buf.deinit(allocator);
    var select_aw = std.Io.Writer.Allocating.fromArrayList(allocator, &select_buf);
    try select_aw.writer.writeAll("SELECT p.path, p.size, m.format, m.width, m.height, m.orientation, m.create_time, m.camera_make, m.camera_model, m.gps_latitude, m.gps_longitude, m.duration_sec, m.has_thumbnail, m.has_animated, m.file_hash ");

    try select_aw.writer.writeAll(base_where);

    // Sorting
    var valid_sort: []const u8 = "path";
    var sort_expr: []const u8 = "p.path";
    const allowed_sort = [_][]const u8{ "path", "size", "format", "width", "height", "duration_sec", "camera_model", "create_time" };
    if (sort_by) |sb| {
        for (allowed_sort) |allowed| {
            if (std.mem.eql(u8, sb, allowed)) {
                valid_sort = allowed;
                break;
            }
        }
    }
    if (std.mem.eql(u8, valid_sort, "path")) {
        sort_expr = "p.path";
    } else if (std.mem.eql(u8, valid_sort, "size")) {
        sort_expr = "p.size";
    } else if (std.mem.eql(u8, valid_sort, "format")) {
        sort_expr = "m.format";
    } else if (std.mem.eql(u8, valid_sort, "width")) {
        sort_expr = "m.width";
    } else if (std.mem.eql(u8, valid_sort, "height")) {
        sort_expr = "m.height";
    } else if (std.mem.eql(u8, valid_sort, "duration_sec")) {
        sort_expr = "m.duration_sec";
    } else if (std.mem.eql(u8, valid_sort, "camera_model")) {
        sort_expr = "m.camera_model";
    } else if (std.mem.eql(u8, valid_sort, "create_time")) {
        sort_expr = normalized_create_time_expr;
    }

    var valid_order: []const u8 = "ASC";
    if (sort_order) |so| {
        if (std.ascii.eqlIgnoreCase(so, "desc")) {
            valid_order = "DESC";
        }
    }
    try select_aw.writer.print(" ORDER BY {s} {s} LIMIT ?{d} OFFSET ?{d};", .{ sort_expr, valid_order, limit_param, offset_param });

    select_buf = select_aw.toArrayList();
    const select_sql = try select_buf.toOwnedSlice(allocator);
    defer allocator.free(select_sql);

    var select_stmt_raw: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, select_sql.ptr, @intCast(select_sql.len), &select_stmt_raw, null) != c.SQLITE_OK) {
        std.debug.print("Failed to prepare select paged query: {s}\n", .{c.sqlite3_errmsg(self.handle)});
        return error.DatabasePrepareError;
    }
    const select_stmt = select_stmt_raw.?;
    defer _ = c.sqlite3_finalize(select_stmt_raw);

    _ = bindFilters(
        select_stmt,
        1,
        search_like,
        format_filter,
        date_from_bound,
        date_to_bound,
        size_min,
        size_max,
    );
    _ = c.sqlite3_bind_int(select_stmt, limit_param, @intCast(limit));
    _ = c.sqlite3_bind_int(select_stmt, offset_param, @intCast(offset));

    var list: std.ArrayList(DbRecord) = .empty;
    errdefer {
        for (list.items) |r| {
            r.deinit(allocator);
            allocator.free(r.path);
            allocator.free(r.format);
        }
        list.deinit(allocator);
    }

    while (c.sqlite3_step(select_stmt) == c.SQLITE_ROW) {
        var record = DbRecord{
            .path = undefined,
            .size = undefined,
            .format = undefined,
        };
        errdefer record.deinit(allocator);

        const path_raw = c.sqlite3_column_text(select_stmt, 0);
        const path_len = c.sqlite3_column_bytes(select_stmt, 0);
        record.path = try allocator.dupe(u8, path_raw[0..@intCast(path_len)]);
        errdefer allocator.free(record.path);

        record.size = @intCast(c.sqlite3_column_int64(select_stmt, 1));

        const fmt_raw = c.sqlite3_column_text(select_stmt, 2);
        if (fmt_raw) |raw| {
            const fmt_len = c.sqlite3_column_bytes(select_stmt, 2);
            record.format = try allocator.dupe(u8, raw[0..@intCast(fmt_len)]);
        } else {
            record.format = try allocator.dupe(u8, "unknown");
        }
        errdefer allocator.free(record.format);

        try fillMetadataFields(allocator, &record, select_stmt, 3, true);

        try list.append(allocator, record);
    }

    return PagedResult{
        .total = total,
        .records = try list.toOwnedSlice(allocator),
    };
}

/// Verify if a path exists in the database.
pub fn pathExists(self: *Db, path: []const u8) !bool {
    if (self.handle == null) return error.DatabaseNotOpen;
    const sql = "SELECT 1 FROM media_paths WHERE path = ? LIMIT 1;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.DatabasePrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    if (c.sqlite3_bind_text(stmt, 1, path.ptr, @intCast(path.len), null) != c.SQLITE_OK) {
        return error.DatabaseBindError;
    }

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        return true;
    }
    return false;
}
