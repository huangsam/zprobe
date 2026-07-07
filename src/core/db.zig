//! SQLite Database caching and media cataloging module.
//!
//! Encapsulates schema definition, cache queries, media record inserts,
//! and bulk transactional batching.

const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

/// Represents a media metadata row stored in the database.
pub const DbRecord = struct {
    path: []const u8,
    size: u64,
    format: []const u8,
    width: ?u32 = null,
    height: ?u32 = null,
    orientation: ?u16 = null,
    create_time: ?[]const u8 = null,
    camera_make: ?[]const u8 = null,
    camera_model: ?[]const u8 = null,
    gps_latitude: ?f64 = null,
    gps_longitude: ?f64 = null,
    duration_sec: ?f64 = null,

    /// Free heap-allocated strings stored within DbRecord.
    pub fn deinit(self: *const DbRecord, allocator: std.mem.Allocator) void {
        if (self.create_time) |s| allocator.free(s);
        if (self.camera_make) |s| allocator.free(s);
        if (self.camera_model) |s| allocator.free(s);
    }
};

/// Result returned from checking the cache.
pub const CacheResult = struct {
    hit: bool,
    json_out: DbRecord = undefined,
};

/// Holds aggregated statistics for dashboard charts and metrics.
pub const DbStats = struct {
    total_files: u32,
    total_size: u64,
    num_images: u32,
    num_videos: u32,
    image_formats: []const FormatCount,
    video_formats: []const FormatCount,
    cameras: []const CameraCount,
    image_sizes: SizeTiers,
    video_sizes: SizeTiers,
    video_durations: DurationTiers,

    pub const FormatCount = struct {
        format: []const u8,
        count: u32,
    };

    pub const CameraCount = struct {
        make: []const u8,
        model: []const u8,
        count: u32,
    };

    pub const SizeTiers = struct {
        tier1: u32,
        tier2: u32,
        tier3: u32,
        tier4: u32,
        tier5: u32,
    };

    pub const DurationTiers = struct {
        tier1: u32,
        tier2: u32,
        tier3: u32,
        tier4: u32,
        tier5: u32,
    };

    pub fn deinit(self: DbStats, allocator: std.mem.Allocator) void {
        for (self.image_formats) |item| allocator.free(item.format);
        allocator.free(self.image_formats);
        for (self.video_formats) |item| allocator.free(item.format);
        allocator.free(self.video_formats);
        for (self.cameras) |item| {
            allocator.free(item.make);
            allocator.free(item.model);
        }
        allocator.free(self.cameras);
    }
};

/// Manager wrapping SQLite database connection and prepared statements.
pub const Db = struct {
    handle: ?*c.sqlite3,
    query_stmt: ?*c.sqlite3_stmt = null,
    insert_stmt: ?*c.sqlite3_stmt = null,
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    /// Initialize SQLite connection, run migrations, and prepare statements.
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Db {
        const db_path_c = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_c);

        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path_c, &handle);
        if (rc != c.SQLITE_OK) {
            if (handle) |h| {
                std.debug.print("Failed to open database: {s}\n", .{c.sqlite3_errmsg(h)});
                _ = c.sqlite3_close(h);
            }
            return error.DatabaseOpenError;
        }
        errdefer _ = c.sqlite3_close(handle);

        // Enable WAL mode and busy timeout for concurrent read/write and to prevent SQLITE_BUSY
        _ = c.sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", null, null, null);
        _ = c.sqlite3_exec(handle, "PRAGMA busy_timeout=5000;", null, null, null);

        const create_table_sql =
            \\CREATE TABLE IF NOT EXISTS media (
            \\    path TEXT PRIMARY KEY,
            \\    size INTEGER,
            \\    mtime INTEGER,
            \\    format TEXT,
            \\    width INTEGER,
            \\    height INTEGER,
            \\    orientation INTEGER,
            \\    create_time TEXT,
            \\    camera_make TEXT,
            \\    camera_model TEXT,
            \\    gps_latitude REAL,
            \\    gps_longitude REAL,
            \\    duration_sec REAL
            \\);
        ;
        var err_msg: [*c]u8 = null;
        const exec_rc = c.sqlite3_exec(handle, create_table_sql, null, null, &err_msg);
        if (exec_rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                std.debug.print("SQL error: {s}\n", .{msg});
                c.sqlite3_free(msg);
            }
            return error.DatabaseSchemaError;
        }

        var query_stmt: ?*c.sqlite3_stmt = null;
        const query_sql = "SELECT size, mtime, format, width, height, orientation, create_time, camera_make, camera_model, gps_latitude, gps_longitude, duration_sec FROM media WHERE path = ?;";
        if (c.sqlite3_prepare_v2(handle, query_sql, -1, &query_stmt, null) != c.SQLITE_OK) {
            std.debug.print("Failed to prepare cache query: {s}\n", .{c.sqlite3_errmsg(handle)});
            return error.DatabasePrepareError;
        }
        errdefer _ = c.sqlite3_finalize(query_stmt);

        var insert_stmt: ?*c.sqlite3_stmt = null;
        const insert_sql = "INSERT OR REPLACE INTO media (path, size, mtime, format, width, height, orientation, create_time, camera_make, camera_model, gps_latitude, gps_longitude, duration_sec) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);";
        if (c.sqlite3_prepare_v2(handle, insert_sql, -1, &insert_stmt, null) != c.SQLITE_OK) {
            std.debug.print("Failed to prepare insert query: {s}\n", .{c.sqlite3_errmsg(handle)});
            _ = c.sqlite3_finalize(query_stmt);
            return error.DatabasePrepareError;
        }

        return Db{
            .handle = handle,
            .query_stmt = query_stmt,
            .insert_stmt = insert_stmt,
        };
    }

    /// Finalize statements and close connection.
    pub fn deinit(self: *Db) void {
        if (self.query_stmt) |stmt| _ = c.sqlite3_finalize(stmt);
        if (self.insert_stmt) |stmt| _ = c.sqlite3_finalize(stmt);
        if (self.handle) |h| _ = c.sqlite3_close(h);
        self.query_stmt = null;
        self.insert_stmt = null;
        self.handle = null;
    }

    /// Begin bulk transaction.
    pub fn beginTransaction(self: *Db) void {
        if (self.handle) |h| {
            _ = c.sqlite3_exec(h, "BEGIN TRANSACTION;", null, null, null);
        }
    }

    /// Commit transaction.
    pub fn commitTransaction(self: *Db) void {
        if (self.handle) |h| {
            _ = c.sqlite3_exec(h, "COMMIT TRANSACTION;", null, null, null);
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
        if (self.handle == null or self.query_stmt == null) return .{ .hit = false };
        const stmt = self.query_stmt.?;

        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
        defer _ = c.sqlite3_reset(stmt);

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

                const fmt_raw = c.sqlite3_column_text(stmt, 2);
                const fmt_len = c.sqlite3_column_bytes(stmt, 2);
                json_out.format = try allocator.dupe(u8, fmt_raw[0..@intCast(fmt_len)]);

                if (c.sqlite3_column_type(stmt, 3) != c.SQLITE_NULL) {
                    json_out.width = @intCast(c.sqlite3_column_int(stmt, 3));
                }
                if (c.sqlite3_column_type(stmt, 4) != c.SQLITE_NULL) {
                    json_out.height = @intCast(c.sqlite3_column_int(stmt, 4));
                }
                if (c.sqlite3_column_type(stmt, 5) != c.SQLITE_NULL) {
                    json_out.orientation = @intCast(c.sqlite3_column_int(stmt, 5));
                }
                if (c.sqlite3_column_type(stmt, 6) != c.SQLITE_NULL) {
                    const raw = c.sqlite3_column_text(stmt, 6);
                    const len = c.sqlite3_column_bytes(stmt, 6);
                    json_out.create_time = try allocator.dupe(u8, raw[0..@intCast(len)]);
                }
                if (c.sqlite3_column_type(stmt, 7) != c.SQLITE_NULL) {
                    const raw = c.sqlite3_column_text(stmt, 7);
                    const len = c.sqlite3_column_bytes(stmt, 7);
                    json_out.camera_make = try allocator.dupe(u8, raw[0..@intCast(len)]);
                }
                if (c.sqlite3_column_type(stmt, 8) != c.SQLITE_NULL) {
                    const raw = c.sqlite3_column_text(stmt, 8);
                    const len = c.sqlite3_column_bytes(stmt, 8);
                    json_out.camera_model = try allocator.dupe(u8, raw[0..@intCast(len)]);
                }
                if (c.sqlite3_column_type(stmt, 9) != c.SQLITE_NULL) {
                    json_out.gps_latitude = c.sqlite3_column_double(stmt, 9);
                }
                if (c.sqlite3_column_type(stmt, 10) != c.SQLITE_NULL) {
                    json_out.gps_longitude = c.sqlite3_column_double(stmt, 10);
                }
                if (c.sqlite3_column_type(stmt, 11) != c.SQLITE_NULL) {
                    json_out.duration_sec = c.sqlite3_column_double(stmt, 11);
                }

                return .{ .hit = true, .json_out = json_out };
            }
        }

        return .{ .hit = false };
    }

    /// Insert or replace a media catalog entry.
    pub fn insertMedia(
        self: *Db,
        json_out: *const DbRecord,
        mtime: i64,
    ) !void {
        if (self.handle == null or self.insert_stmt == null) return;
        const stmt = self.insert_stmt.?;

        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
        defer _ = c.sqlite3_reset(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, json_out.path.ptr, @intCast(json_out.path.len), null);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(json_out.size));
        _ = c.sqlite3_bind_int64(stmt, 3, mtime);
        _ = c.sqlite3_bind_text(stmt, 4, json_out.format.ptr, @intCast(json_out.format.len), null);

        if (json_out.width) |w| {
            _ = c.sqlite3_bind_int(stmt, 5, @intCast(w));
        } else {
            _ = c.sqlite3_bind_null(stmt, 5);
        }

        if (json_out.height) |h| {
            _ = c.sqlite3_bind_int(stmt, 6, @intCast(h));
        } else {
            _ = c.sqlite3_bind_null(stmt, 6);
        }

        if (json_out.orientation) |o| {
            _ = c.sqlite3_bind_int(stmt, 7, @intCast(o));
        } else {
            _ = c.sqlite3_bind_null(stmt, 7);
        }

        if (json_out.create_time) |ct| {
            _ = c.sqlite3_bind_text(stmt, 8, ct.ptr, @intCast(ct.len), null);
        } else {
            _ = c.sqlite3_bind_null(stmt, 8);
        }

        if (json_out.camera_make) |cm| {
            _ = c.sqlite3_bind_text(stmt, 9, cm.ptr, @intCast(cm.len), null);
        } else {
            _ = c.sqlite3_bind_null(stmt, 9);
        }

        if (json_out.camera_model) |cm| {
            _ = c.sqlite3_bind_text(stmt, 10, cm.ptr, @intCast(cm.len), null);
        } else {
            _ = c.sqlite3_bind_null(stmt, 10);
        }

        if (json_out.gps_latitude) |lat| {
            _ = c.sqlite3_bind_double(stmt, 11, lat);
        } else {
            _ = c.sqlite3_bind_null(stmt, 11);
        }

        if (json_out.gps_longitude) |lon| {
            _ = c.sqlite3_bind_double(stmt, 12, lon);
        } else {
            _ = c.sqlite3_bind_null(stmt, 12);
        }

        if (json_out.duration_sec) |dur| {
            _ = c.sqlite3_bind_double(stmt, 13, dur);
        } else {
            _ = c.sqlite3_bind_null(stmt, 13);
        }

        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) {
            std.debug.print("Failed to insert media row: {s}\n", .{c.sqlite3_errmsg(self.handle)});
        }
    }

    /// Retrieve all media catalog entries from the database.
    /// The caller owns the returned slice and all nested heap-allocated strings,
    /// and must free them (e.g., by calling freeAllRecords).
    pub fn getAllRecords(self: *Db, allocator: std.mem.Allocator) ![]DbRecord {
        if (self.handle == null) return error.DatabaseNotOpen;

        const select_sql = "SELECT path, size, format, width, height, orientation, create_time, camera_make, camera_model, gps_latitude, gps_longitude, duration_sec FROM media;";
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

            const path_raw = c.sqlite3_column_text(stmt, 0);
            const path_len = c.sqlite3_column_bytes(stmt, 0);
            record.path = try allocator.dupe(u8, path_raw[0..@intCast(path_len)]);
            errdefer allocator.free(record.path);

            record.size = @intCast(c.sqlite3_column_int64(stmt, 1));

            const fmt_raw = c.sqlite3_column_text(stmt, 2);
            const fmt_len = c.sqlite3_column_bytes(stmt, 2);
            record.format = try allocator.dupe(u8, fmt_raw[0..@intCast(fmt_len)]);
            errdefer allocator.free(record.format);

            if (c.sqlite3_column_type(stmt, 3) != c.SQLITE_NULL) {
                record.width = @intCast(c.sqlite3_column_int(stmt, 3));
            }
            if (c.sqlite3_column_type(stmt, 4) != c.SQLITE_NULL) {
                record.height = @intCast(c.sqlite3_column_int(stmt, 4));
            }
            if (c.sqlite3_column_type(stmt, 5) != c.SQLITE_NULL) {
                record.orientation = @intCast(c.sqlite3_column_int(stmt, 5));
            }
            if (c.sqlite3_column_type(stmt, 6) != c.SQLITE_NULL) {
                const raw = c.sqlite3_column_text(stmt, 6);
                const len = c.sqlite3_column_bytes(stmt, 6);
                record.create_time = try allocator.dupe(u8, raw[0..@intCast(len)]);
            }
            if (c.sqlite3_column_type(stmt, 7) != c.SQLITE_NULL) {
                const raw = c.sqlite3_column_text(stmt, 7);
                const len = c.sqlite3_column_bytes(stmt, 7);
                record.camera_make = try allocator.dupe(u8, raw[0..@intCast(len)]);
            }
            if (c.sqlite3_column_type(stmt, 8) != c.SQLITE_NULL) {
                const raw = c.sqlite3_column_text(stmt, 8);
                const len = c.sqlite3_column_bytes(stmt, 8);
                record.camera_model = try allocator.dupe(u8, raw[0..@intCast(len)]);
            }
            if (c.sqlite3_column_type(stmt, 9) != c.SQLITE_NULL) {
                record.gps_latitude = c.sqlite3_column_double(stmt, 9);
            }
            if (c.sqlite3_column_type(stmt, 10) != c.SQLITE_NULL) {
                record.gps_longitude = c.sqlite3_column_double(stmt, 10);
            }
            if (c.sqlite3_column_type(stmt, 11) != c.SQLITE_NULL) {
                record.duration_sec = c.sqlite3_column_double(stmt, 11);
            }

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

        // 1. Overall stats
        var total_files: u32 = 0;
        var total_size: u64 = 0;
        var num_images: u32 = 0;
        var num_videos: u32 = 0;

        const overall_sql =
            \\SELECT 
            \\    COUNT(*), 
            \\    COALESCE(SUM(size), 0),
            \\    COALESCE(SUM(CASE WHEN duration_sec IS NULL AND format NOT IN ('mp4', 'webm', 'mkv', 'mov', 'avi') THEN 1 ELSE 0 END), 0),
            \\    COALESCE(SUM(CASE WHEN duration_sec IS NOT NULL OR format IN ('mp4', 'webm', 'mkv', 'mov', 'avi') THEN 1 ELSE 0 END), 0)
            \\FROM media;
        ;
        var overall_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, overall_sql, -1, &overall_stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(overall_stmt);
            if (c.sqlite3_step(overall_stmt) == c.SQLITE_ROW) {
                total_files = @intCast(c.sqlite3_column_int(overall_stmt, 0));
                total_size = @intCast(c.sqlite3_column_int64(overall_stmt, 1));
                num_images = @intCast(c.sqlite3_column_int(overall_stmt, 2));
                num_videos = @intCast(c.sqlite3_column_int(overall_stmt, 3));
            }
        }

        // 2. Image formats
        const img_fmt_sql =
            \\SELECT format, COUNT(*) 
            \\FROM media 
            \\WHERE duration_sec IS NULL AND format NOT IN ('mp4', 'webm', 'mkv', 'mov', 'avi')
            \\GROUP BY format;
        ;
        var img_formats: std.ArrayList(DbStats.FormatCount) = .empty;
        errdefer {
            for (img_formats.items) |item| allocator.free(item.format);
            img_formats.deinit(allocator);
        }
        var img_fmt_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, img_fmt_sql, -1, &img_fmt_stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(img_fmt_stmt);
            while (c.sqlite3_step(img_fmt_stmt) == c.SQLITE_ROW) {
                const raw = c.sqlite3_column_text(img_fmt_stmt, 0);
                const len = c.sqlite3_column_bytes(img_fmt_stmt, 0);
                const count = @as(u32, @intCast(c.sqlite3_column_int(img_fmt_stmt, 1)));
                try img_formats.append(allocator, .{
                    .format = try allocator.dupe(u8, raw[0..@intCast(len)]),
                    .count = count,
                });
            }
        }

        // 3. Video formats
        const vid_fmt_sql =
            \\SELECT format, COUNT(*) 
            \\FROM media 
            \\WHERE duration_sec IS NOT NULL OR format IN ('mp4', 'webm', 'mkv', 'mov', 'avi')
            \\GROUP BY format;
        ;
        var vid_formats: std.ArrayList(DbStats.FormatCount) = .empty;
        errdefer {
            for (vid_formats.items) |item| allocator.free(item.format);
            vid_formats.deinit(allocator);
        }
        var vid_fmt_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, vid_fmt_sql, -1, &vid_fmt_stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(vid_fmt_stmt);
            while (c.sqlite3_step(vid_fmt_stmt) == c.SQLITE_ROW) {
                const raw = c.sqlite3_column_text(vid_fmt_stmt, 0);
                const len = c.sqlite3_column_bytes(vid_fmt_stmt, 0);
                const count = @as(u32, @intCast(c.sqlite3_column_int(vid_fmt_stmt, 1)));
                try vid_formats.append(allocator, .{
                    .format = try allocator.dupe(u8, raw[0..@intCast(len)]),
                    .count = count,
                });
            }
        }

        // 4. Cameras (top 5)
        const cameras_sql =
            \\SELECT COALESCE(camera_make, ''), COALESCE(camera_model, ''), COUNT(*)
            \\FROM media
            \\WHERE duration_sec IS NULL AND format NOT IN ('mp4', 'webm', 'mkv', 'mov', 'avi')
            \\  AND (camera_make IS NOT NULL OR camera_model IS NOT NULL)
            \\GROUP BY camera_make, camera_model
            \\ORDER BY COUNT(*) DESC
            \\LIMIT 5;
        ;
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

        // 5. Image sizes distribution
        const img_sizes_sql =
            \\SELECT 
            \\    COALESCE(SUM(CASE WHEN size < 1048576 THEN 1 ELSE 0 END), 0),
            \\    COALESCE(SUM(CASE WHEN size >= 1048576 AND size < 5242880 THEN 1 ELSE 0 END), 0),
            \\    COALESCE(SUM(CASE WHEN size >= 5242880 AND size < 10485760 THEN 1 ELSE 0 END), 0),
            \\    COALESCE(SUM(CASE WHEN size >= 10485760 AND size < 26214400 THEN 1 ELSE 0 END), 0),
            \\    COALESCE(SUM(CASE WHEN size >= 26214400 THEN 1 ELSE 0 END), 0)
            \\FROM media
            \\WHERE duration_sec IS NULL AND format NOT IN ('mp4', 'webm', 'mkv', 'mov', 'avi');
        ;
        var img_sizes = DbStats.SizeTiers{ .tier1 = 0, .tier2 = 0, .tier3 = 0, .tier4 = 0, .tier5 = 0 };
        var img_sizes_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, img_sizes_sql, -1, &img_sizes_stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(img_sizes_stmt);
            if (c.sqlite3_step(img_sizes_stmt) == c.SQLITE_ROW) {
                img_sizes.tier1 = @intCast(c.sqlite3_column_int(img_sizes_stmt, 0));
                img_sizes.tier2 = @intCast(c.sqlite3_column_int(img_sizes_stmt, 1));
                img_sizes.tier3 = @intCast(c.sqlite3_column_int(img_sizes_stmt, 2));
                img_sizes.tier4 = @intCast(c.sqlite3_column_int(img_sizes_stmt, 3));
                img_sizes.tier5 = @intCast(c.sqlite3_column_int(img_sizes_stmt, 4));
            }
        }

        // 6. Video sizes distribution
        const vid_sizes_sql =
            \\SELECT 
            \\    COALESCE(SUM(CASE WHEN size < 10485760 THEN 1 ELSE 0 END), 0),
            \\    COALESCE(SUM(CASE WHEN size >= 10485760 AND size < 104857600 THEN 1 ELSE 0 END), 0),
            \\    COALESCE(SUM(CASE WHEN size >= 104857600 AND size < 524288000 THEN 1 ELSE 0 END), 0),
            \\    COALESCE(SUM(CASE WHEN size >= 524288000 AND size < 2147483648 THEN 1 ELSE 0 END), 0),
            \\    COALESCE(SUM(CASE WHEN size >= 2147483648 THEN 1 ELSE 0 END), 0)
            \\FROM media
            \\WHERE duration_sec IS NOT NULL OR format IN ('mp4', 'webm', 'mkv', 'mov', 'avi');
        ;
        var vid_sizes = DbStats.SizeTiers{ .tier1 = 0, .tier2 = 0, .tier3 = 0, .tier4 = 0, .tier5 = 0 };
        var vid_sizes_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, vid_sizes_sql, -1, &vid_sizes_stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(vid_sizes_stmt);
            if (c.sqlite3_step(vid_sizes_stmt) == c.SQLITE_ROW) {
                vid_sizes.tier1 = @intCast(c.sqlite3_column_int(vid_sizes_stmt, 0));
                vid_sizes.tier2 = @intCast(c.sqlite3_column_int(vid_sizes_stmt, 1));
                vid_sizes.tier3 = @intCast(c.sqlite3_column_int(vid_sizes_stmt, 2));
                vid_sizes.tier4 = @intCast(c.sqlite3_column_int(vid_sizes_stmt, 3));
                vid_sizes.tier5 = @intCast(c.sqlite3_column_int(vid_sizes_stmt, 4));
            }
        }

        // 7. Video durations distribution
        const vid_durations_sql =
            \\SELECT 
            \\    COALESCE(SUM(CASE WHEN duration_sec < 10 THEN 1 ELSE 0 END), 0),
            \\    COALESCE(SUM(CASE WHEN duration_sec >= 10 AND duration_sec < 60 THEN 1 ELSE 0 END), 0),
            \\    COALESCE(SUM(CASE WHEN duration_sec >= 60 AND duration_sec < 300 THEN 1 ELSE 0 END), 0),
            \\    COALESCE(SUM(CASE WHEN duration_sec >= 300 AND duration_sec < 900 THEN 1 ELSE 0 END), 0),
            \\    COALESCE(SUM(CASE WHEN duration_sec >= 900 THEN 1 ELSE 0 END), 0)
            \\FROM media
            \\WHERE duration_sec IS NOT NULL OR format IN ('mp4', 'webm', 'mkv', 'mov', 'avi');
        ;
        var vid_durations = DbStats.DurationTiers{ .tier1 = 0, .tier2 = 0, .tier3 = 0, .tier4 = 0, .tier5 = 0 };
        var vid_durations_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, vid_durations_sql, -1, &vid_durations_stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(vid_durations_stmt);
            if (c.sqlite3_step(vid_durations_stmt) == c.SQLITE_ROW) {
                vid_durations.tier1 = @intCast(c.sqlite3_column_int(vid_durations_stmt, 0));
                vid_durations.tier2 = @intCast(c.sqlite3_column_int(vid_durations_stmt, 1));
                vid_durations.tier3 = @intCast(c.sqlite3_column_int(vid_durations_stmt, 2));
                vid_durations.tier4 = @intCast(c.sqlite3_column_int(vid_durations_stmt, 3));
                vid_durations.tier5 = @intCast(c.sqlite3_column_int(vid_durations_stmt, 4));
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

    pub const PagedResult = struct {
        total: u32,
        records: []DbRecord,
    };

    /// Retrieve a page of filtered, searched, and sorted media catalog entries.
    pub fn getRecordsPaged(
        self: *Db,
        allocator: std.mem.Allocator,
        limit: u32,
        offset: u32,
        search: ?[]const u8,
        format_filter: ?[]const u8,
        type_filter: ?[]const u8,
        sort_by: ?[]const u8,
        sort_order: ?[]const u8,
    ) !PagedResult {
        if (self.handle == null) return error.DatabaseNotOpen;

        // Build WHERE clauses dynamically
        var query_buf: std.ArrayList(u8) = .empty;
        defer query_buf.deinit(allocator);

        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &query_buf);
        const writer = &aw.writer;

        try writer.writeAll("FROM media WHERE 1=1");

        if (search) |_| {
            try writer.writeAll(" AND (path LIKE ?1 OR camera_make LIKE ?1 OR camera_model LIKE ?1 OR format LIKE ?1)");
        }
        if (format_filter) |_| {
            try writer.writeAll(" AND format = ?2");
        }
        if (type_filter) |t| {
            if (std.mem.eql(u8, t, "image")) {
                try writer.writeAll(" AND (duration_sec IS NULL AND format NOT IN ('mp4', 'webm', 'mkv', 'mov', 'avi'))");
            } else if (std.mem.eql(u8, t, "video")) {
                try writer.writeAll(" AND (duration_sec IS NOT NULL OR format IN ('mp4', 'webm', 'mkv', 'mov', 'avi'))");
            }
        }

        query_buf = aw.toArrayList();
        const base_where = try query_buf.toOwnedSlice(allocator);
        defer allocator.free(base_where);

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

        var count_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, count_sql.ptr, @intCast(count_sql.len), &count_stmt, null) != c.SQLITE_OK) {
            std.debug.print("Failed to prepare count query: {s}\n", .{c.sqlite3_errmsg(self.handle)});
            return error.DatabasePrepareError;
        }
        defer _ = c.sqlite3_finalize(count_stmt);

        // Keep search_like alive until execution completes to avoid pointer lifetime issues with sqlite3_bind_text
        var search_like: ?[]const u8 = null;
        defer if (search_like) |sl| allocator.free(sl);

        if (search) |s| {
            search_like = try std.fmt.allocPrint(allocator, "%{s}%", .{s});
            _ = c.sqlite3_bind_text(count_stmt, 1, search_like.?.ptr, @intCast(search_like.?.len), null);
        }
        if (format_filter) |f| {
            _ = c.sqlite3_bind_text(count_stmt, 2, f.ptr, @intCast(f.len), null);
        }

        var total: u32 = 0;
        if (c.sqlite3_step(count_stmt) == c.SQLITE_ROW) {
            total = @intCast(c.sqlite3_column_int(count_stmt, 0));
        }

        // 2. Fetch records
        var select_buf: std.ArrayList(u8) = .empty;
        defer select_buf.deinit(allocator);
        var select_aw = std.Io.Writer.Allocating.fromArrayList(allocator, &select_buf);
        try select_aw.writer.writeAll("SELECT path, size, format, width, height, orientation, create_time, camera_make, camera_model, gps_latitude, gps_longitude, duration_sec ");
        try select_aw.writer.writeAll(base_where);

        // Sorting
        var valid_sort: []const u8 = "path";
        const allowed_sort = [_][]const u8{ "path", "size", "format", "width", "height", "duration_sec", "camera_model", "create_time" };
        if (sort_by) |sb| {
            for (allowed_sort) |allowed| {
                if (std.mem.eql(u8, sb, allowed)) {
                    valid_sort = allowed;
                    break;
                }
            }
        }
        var valid_order: []const u8 = "ASC";
        if (sort_order) |so| {
            if (std.ascii.eqlIgnoreCase(so, "desc")) {
                valid_order = "DESC";
            }
        }
        try select_aw.writer.print(" ORDER BY {s} {s} LIMIT ?3 OFFSET ?4;", .{ valid_sort, valid_order });

        select_buf = select_aw.toArrayList();
        const select_sql = try select_buf.toOwnedSlice(allocator);
        defer allocator.free(select_sql);

        var select_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, select_sql.ptr, @intCast(select_sql.len), &select_stmt, null) != c.SQLITE_OK) {
            std.debug.print("Failed to prepare select paged query: {s}\n", .{c.sqlite3_errmsg(self.handle)});
            return error.DatabasePrepareError;
        }
        defer _ = c.sqlite3_finalize(select_stmt);

        // Bind parameters for select
        if (search_like) |sl| {
            _ = c.sqlite3_bind_text(select_stmt, 1, sl.ptr, @intCast(sl.len), null);
        }
        if (format_filter) |f| {
            _ = c.sqlite3_bind_text(select_stmt, 2, f.ptr, @intCast(f.len), null);
        }
        _ = c.sqlite3_bind_int(select_stmt, 3, @intCast(limit));
        _ = c.sqlite3_bind_int(select_stmt, 4, @intCast(offset));

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

            const path_raw = c.sqlite3_column_text(select_stmt, 0);
            const path_len = c.sqlite3_column_bytes(select_stmt, 0);
            record.path = try allocator.dupe(u8, path_raw[0..@intCast(path_len)]);
            errdefer allocator.free(record.path);

            record.size = @intCast(c.sqlite3_column_int64(select_stmt, 1));

            const fmt_raw = c.sqlite3_column_text(select_stmt, 2);
            const fmt_len = c.sqlite3_column_bytes(select_stmt, 2);
            record.format = try allocator.dupe(u8, fmt_raw[0..@intCast(fmt_len)]);
            errdefer allocator.free(record.format);

            if (c.sqlite3_column_type(select_stmt, 3) != c.SQLITE_NULL) {
                record.width = @intCast(c.sqlite3_column_int(select_stmt, 3));
            }
            if (c.sqlite3_column_type(select_stmt, 4) != c.SQLITE_NULL) {
                record.height = @intCast(c.sqlite3_column_int(select_stmt, 4));
            }
            if (c.sqlite3_column_type(select_stmt, 5) != c.SQLITE_NULL) {
                record.orientation = @intCast(c.sqlite3_column_int(select_stmt, 5));
            }
            if (c.sqlite3_column_type(select_stmt, 6) != c.SQLITE_NULL) {
                const raw = c.sqlite3_column_text(select_stmt, 6);
                const len = c.sqlite3_column_bytes(select_stmt, 6);
                record.create_time = try allocator.dupe(u8, raw[0..@intCast(len)]);
            }
            if (c.sqlite3_column_type(select_stmt, 7) != c.SQLITE_NULL) {
                const raw = c.sqlite3_column_text(select_stmt, 7);
                const len = c.sqlite3_column_bytes(select_stmt, 7);
                record.camera_make = try allocator.dupe(u8, raw[0..@intCast(len)]);
            }
            if (c.sqlite3_column_type(select_stmt, 8) != c.SQLITE_NULL) {
                const raw = c.sqlite3_column_text(select_stmt, 8);
                const len = c.sqlite3_column_bytes(select_stmt, 8);
                record.camera_model = try allocator.dupe(u8, raw[0..@intCast(len)]);
            }
            if (c.sqlite3_column_type(select_stmt, 9) != c.SQLITE_NULL) {
                record.gps_latitude = c.sqlite3_column_double(select_stmt, 9);
            }
            if (c.sqlite3_column_type(select_stmt, 10) != c.SQLITE_NULL) {
                record.gps_longitude = c.sqlite3_column_double(select_stmt, 10);
            }
            if (c.sqlite3_column_type(select_stmt, 11) != c.SQLITE_NULL) {
                record.duration_sec = c.sqlite3_column_double(select_stmt, 11);
            }

            try list.append(allocator, record);
        }

        return PagedResult{
            .total = total,
            .records = try list.toOwnedSlice(allocator),
        };
    }
};
