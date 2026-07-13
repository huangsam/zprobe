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

/// SQL predicate matching image rows (shared across stats and filter queries).
const is_image_pred = "(duration_sec IS NULL AND format NOT IN ('mp4', 'webm', 'mkv', 'mov', 'avi'))";

/// SQL predicate matching video rows (shared across stats and filter queries).
const is_video_pred = "(duration_sec IS NOT NULL OR format IN ('mp4', 'webm', 'mkv', 'mov', 'avi'))";

/// Stats cache TTL — short enough to reflect crawler writes, long enough to absorb dashboard polling.
const stats_cache_ttl_ns: i96 = 2 * std.time.ns_per_s;

const PagedStmtCache = struct {
    const max_entries = 16;

    entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,
    len: usize = 0,

    const Entry = struct {
        sql: ?[]const u8 = null,
        stmt: ?*c.sqlite3_stmt = null,
    };

    fn get(self: *const PagedStmtCache, sql: []const u8) ?*c.sqlite3_stmt {
        for (self.entries[0..self.len]) |entry| {
            if (entry.sql) |cached_sql| {
                if (std.mem.eql(u8, cached_sql, sql)) return entry.stmt;
            }
        }
        return null;
    }

    fn put(
        self: *PagedStmtCache,
        allocator: std.mem.Allocator,
        handle: *c.sqlite3,
        sql: []const u8,
    ) !*c.sqlite3_stmt {
        if (self.get(sql)) |stmt| return stmt;

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
            return error.DatabasePrepareError;
        }

        const dup_sql = try allocator.dupe(u8, sql);
        errdefer allocator.free(dup_sql);

        if (self.len < max_entries) {
            self.entries[self.len] = .{ .sql = dup_sql, .stmt = stmt.? };
            self.len += 1;
            return stmt.?;
        }

        // Evict the oldest entry when the cache is full.
        if (self.entries[0].sql) |old_sql| allocator.free(old_sql);
        if (self.entries[0].stmt) |old_stmt| _ = c.sqlite3_finalize(old_stmt);
        for (1..self.len) |i| {
            self.entries[i - 1] = self.entries[i];
        }
        self.entries[self.len - 1] = .{ .sql = dup_sql, .stmt = stmt.? };
        return stmt.?;
    }

    fn deinit(self: *PagedStmtCache, allocator: std.mem.Allocator) void {
        for (self.entries[0..self.len]) |entry| {
            if (entry.sql) |sql| allocator.free(sql);
            if (entry.stmt) |stmt| _ = c.sqlite3_finalize(stmt);
        }
        self.len = 0;
    }
};

/// Manager wrapping SQLite database connection and prepared statements.
pub const Db = struct {
    allocator: std.mem.Allocator,
    handle: ?*c.sqlite3,
    query_stmt: ?*c.sqlite3_stmt = null,
    insert_stmt: ?*c.sqlite3_stmt = null,
    rwlock: std.Io.RwLock = std.Io.RwLock.init,
    stats_cache: ?DbStats = null,
    stats_cache_expires_ns: i96 = 0,
    stats_cache_arena: std.heap.ArenaAllocator,
    paged_stmt_cache: PagedStmtCache = .{},
    paged_stmt_cache_arena: std.heap.ArenaAllocator,

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

        const create_indices_sql =
            \\CREATE INDEX IF NOT EXISTS idx_media_size ON media(size);
            \\CREATE INDEX IF NOT EXISTS idx_media_create_time ON media(create_time);
            \\CREATE INDEX IF NOT EXISTS idx_media_format ON media(format);
        ;
        err_msg = null;
        const indices_rc = c.sqlite3_exec(handle, create_indices_sql, null, null, &err_msg);
        if (indices_rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                std.debug.print("SQL error creating indices: {s}\n", .{msg});
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
            .allocator = allocator,
            .handle = handle,
            .query_stmt = query_stmt,
            .insert_stmt = insert_stmt,
            .stats_cache_arena = std.heap.ArenaAllocator.init(allocator),
            .paged_stmt_cache_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    /// Acquire a shared lock for read-only database operations.
    pub fn lockRead(self: *Db, io: std.Io) void {
        self.rwlock.lockSharedUncancelable(io);
    }

    /// Release a shared read lock.
    pub fn unlockRead(self: *Db, io: std.Io) void {
        self.rwlock.unlockShared(io);
    }

    /// Acquire an exclusive lock for write operations.
    pub fn lockWrite(self: *Db, io: std.Io) void {
        self.rwlock.lockUncancelable(io);
    }

    /// Release an exclusive write lock.
    pub fn unlockWrite(self: *Db, io: std.Io) void {
        self.rwlock.unlock(io);
    }

    fn invalidateStatsCache(self: *Db) void {
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
        const now = std.Io.Clock.real.now(io).nanoseconds;
        if (self.stats_cache) |cached| {
            if (now < self.stats_cache_expires_ns) {
                return try cloneStats(allocator, cached);
            }
        }

        self.stats_cache_arena.deinit();
        self.stats_cache_arena = std.heap.ArenaAllocator.init(self.allocator);
        const cache_alloc = self.stats_cache_arena.allocator();

        const fresh = try self.getStats(cache_alloc);
        self.stats_cache = fresh;
        self.stats_cache_expires_ns = now + stats_cache_ttl_ns;

        return try cloneStats(allocator, fresh);
    }

    fn getOrPreparePagedStmt(self: *Db, sql: []const u8) !*c.sqlite3_stmt {
        if (self.paged_stmt_cache.get(sql)) |stmt| return stmt;
        return self.paged_stmt_cache.put(
            self.paged_stmt_cache_arena.allocator(),
            self.handle.?,
            sql,
        );
    }

    /// Finalize statements and close connection.
    pub fn deinit(self: *Db) void {
        self.paged_stmt_cache.deinit(self.paged_stmt_cache_arena.allocator());
        self.paged_stmt_cache_arena.deinit();
        self.stats_cache_arena.deinit();
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
            self.invalidateStatsCache();
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
                if (fmt_raw) |raw| {
                    const fmt_len = c.sqlite3_column_bytes(stmt, 2);
                    json_out.format = try allocator.dupe(u8, raw[0..@intCast(fmt_len)]);
                } else {
                    json_out.format = try allocator.dupe(u8, "unknown");
                }

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
        } else {
            self.invalidateStatsCache();
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
            if (fmt_raw) |raw| {
                const fmt_len = c.sqlite3_column_bytes(stmt, 2);
                record.format = try allocator.dupe(u8, raw[0..@intCast(fmt_len)]);
            } else {
                record.format = try allocator.dupe(u8, "unknown");
            }
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
            "COUNT(*), " ++
            "COALESCE(SUM(size), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_image_pred ++ " THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_video_pred ++ " THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_image_pred ++ " AND size < 1048576 THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_image_pred ++ " AND size >= 1048576 AND size < 5242880 THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_image_pred ++ " AND size >= 5242880 AND size < 10485760 THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_image_pred ++ " AND size >= 10485760 AND size < 26214400 THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_image_pred ++ " AND size >= 26214400 THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_video_pred ++ " AND size < 10485760 THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_video_pred ++ " AND size >= 10485760 AND size < 104857600 THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_video_pred ++ " AND size >= 104857600 AND size < 524288000 THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_video_pred ++ " AND size >= 524288000 AND size < 2147483648 THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_video_pred ++ " AND size >= 2147483648 THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_video_pred ++ " AND duration_sec < 10 THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_video_pred ++ " AND duration_sec >= 10 AND duration_sec < 60 THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_video_pred ++ " AND duration_sec >= 60 AND duration_sec < 300 THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_video_pred ++ " AND duration_sec >= 300 AND duration_sec < 900 THEN 1 ELSE 0 END), 0), " ++
            "COALESCE(SUM(CASE WHEN " ++ is_video_pred ++ " AND duration_sec >= 900 THEN 1 ELSE 0 END), 0) " ++
            "FROM media;";
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
            "SELECT 'image' AS kind, COALESCE(format, 'unknown') AS format, COUNT(*) " ++
            "FROM media WHERE " ++ is_image_pred ++ " GROUP BY format " ++
            "UNION ALL " ++
            "SELECT 'video' AS kind, COALESCE(format, 'unknown') AS format, COUNT(*) " ++
            "FROM media WHERE " ++ is_video_pred ++ " GROUP BY format;";
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
            "SELECT COALESCE(camera_make, ''), COALESCE(camera_model, ''), COUNT(*) " ++
            "FROM media WHERE " ++ is_image_pred ++ " " ++
            "AND (camera_make IS NOT NULL OR camera_model IS NOT NULL) " ++
            "GROUP BY camera_make, camera_model " ++
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

    pub const PagedResult = struct {
        total: u32,
        records: []DbRecord,
    };

    /// SQL expression that normalizes EXIF "YYYY:MM:DD ..." to "YYYY-MM-DD ...".
    const normalized_create_time_expr =
        "REPLACE(SUBSTR(create_time, 1, 10), ':', '-') || SUBSTR(create_time, 11)";

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

        try writer.writeAll("FROM media WHERE 1=1");

        var next_param: c_int = 1;

        if (search) |_| {
            try writer.print(
                " AND (path LIKE ?{d} OR camera_make LIKE ?{d} OR camera_model LIKE ?{d} OR format LIKE ?{d})",
                .{ next_param, next_param, next_param, next_param },
            );
            next_param += 1;
        }
        if (format_filter) |_| {
            try writer.print(" AND format = ?{d}", .{next_param});
            next_param += 1;
        }
        if (type_filter) |t| {
            if (std.mem.eql(u8, t, "image")) {
                try writer.writeAll(" AND (duration_sec IS NULL AND format NOT IN ('mp4', 'webm', 'mkv', 'mov', 'avi'))");
            } else if (std.mem.eql(u8, t, "video")) {
                try writer.writeAll(" AND (duration_sec IS NOT NULL OR format IN ('mp4', 'webm', 'mkv', 'mov', 'avi'))");
            }
        }
        if (date_from) |_| {
            try writer.print(" AND create_time IS NOT NULL AND " ++ normalized_create_time_expr ++ " >= ?{d}", .{next_param});
            next_param += 1;
        }
        if (date_to) |_| {
            try writer.print(" AND create_time IS NOT NULL AND " ++ normalized_create_time_expr ++ " <= ?{d}", .{next_param});
            next_param += 1;
        }
        if (size_min) |_| {
            try writer.print(" AND size >= ?{d}", .{next_param});
            next_param += 1;
        }
        if (size_max) |_| {
            try writer.print(" AND size <= ?{d}", .{next_param});
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
                s_like: ?[]const u8,
                fmt: ?[]const u8,
                d_from: ?[]const u8,
                d_to: ?[]const u8,
                s_min: ?u64,
                s_max: ?u64,
            ) void {
                var idx: c_int = 1;
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
                }
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

        const count_stmt = self.getOrPreparePagedStmt(count_sql) catch {
            std.debug.print("Failed to prepare count query: {s}\n", .{c.sqlite3_errmsg(self.handle)});
            return error.DatabasePrepareError;
        };
        defer {
            _ = c.sqlite3_reset(count_stmt);
            _ = c.sqlite3_clear_bindings(count_stmt);
        }

        bindFilters(
            count_stmt,
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
        try select_aw.writer.writeAll("SELECT path, size, format, width, height, orientation, create_time, camera_make, camera_model, gps_latitude, gps_longitude, duration_sec ");
        try select_aw.writer.writeAll(base_where);

        // Sorting
        var valid_sort: []const u8 = "path";
        var sort_expr: []const u8 = "path";
        const allowed_sort = [_][]const u8{ "path", "size", "format", "width", "height", "duration_sec", "camera_model", "create_time" };
        if (sort_by) |sb| {
            for (allowed_sort) |allowed| {
                if (std.mem.eql(u8, sb, allowed)) {
                    valid_sort = allowed;
                    break;
                }
            }
        }
        if (std.mem.eql(u8, valid_sort, "create_time")) {
            sort_expr = normalized_create_time_expr;
        } else {
            sort_expr = valid_sort;
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

        const select_stmt = self.getOrPreparePagedStmt(select_sql) catch {
            std.debug.print("Failed to prepare select paged query: {s}\n", .{c.sqlite3_errmsg(self.handle)});
            return error.DatabasePrepareError;
        };
        defer {
            _ = c.sqlite3_reset(select_stmt);
            _ = c.sqlite3_clear_bindings(select_stmt);
        }

        bindFilters(
            select_stmt,
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

// --- test helpers ---

const test_utils = @import("test_utils.zig");

const TestDb = struct {
    db: Db,
    tmp_ctx: test_utils.TempDirContext,
    path: []const u8,

    fn deinit(self: *TestDb, allocator: std.mem.Allocator) void {
        self.db.deinit();
        allocator.free(self.path);
        self.tmp_ctx.cleanup();
    }
};

fn testDb(allocator: std.mem.Allocator) !TestDb {
    const io = std.testing.io;
    var tmp_ctx = try test_utils.TempDirContext.init(allocator, io);
    errdefer tmp_ctx.cleanup();

    const path = try std.fmt.allocPrint(allocator, "{s}/zprobe_test.db", .{tmp_ctx.abs_path});
    errdefer allocator.free(path);

    var database = try Db.init(allocator, path);
    errdefer database.deinit();

    try seedFixture(&database);

    return .{
        .db = database,
        .tmp_ctx = tmp_ctx,
        .path = path,
    };
}

fn seedRecord(db: *Db, record: DbRecord, mtime: i64) !void {
    try db.insertMedia(&record, mtime);
}

fn seedFixture(db: *Db) !void {
    try seedRecord(db, .{
        .path = "/photos/a.jpg",
        .size = 500_000,
        .format = "jpeg",
        .create_time = "2026:06:27 10:15:30",
    }, 1);
    try seedRecord(db, .{
        .path = "/photos/b.jpg",
        .size = 2_000_000,
        .format = "jpeg",
        .create_time = "2026-06-14 12:00:00",
    }, 2);
    try seedRecord(db, .{
        .path = "/photos/c.png",
        .size = 50_000,
        .format = "png",
    }, 3);
    try seedRecord(db, .{
        .path = "/videos/d.mp4",
        .size = 1_500_000_000,
        .format = "mp4",
        .create_time = "2024-08-04 21:00:57",
        .duration_sec = 22.6,
    }, 4);
    try seedRecord(db, .{
        .path = "/videos/e.mov",
        .size = 24_000_000,
        .format = "mov",
        .create_time = "2022-07-31 23:52:28",
        .duration_sec = 6.6,
    }, 5);
    try seedRecord(db, .{
        .path = "/photos/f.tiff",
        .size = 800_000,
        .format = "tiff",
        .create_time = "2015-04-10 00:07:02",
    }, 6);
}

fn freeRecords(allocator: std.mem.Allocator, records: []DbRecord) void {
    for (records) |r| {
        r.deinit(allocator);
        allocator.free(r.path);
        allocator.free(r.format);
    }
    allocator.free(records);
}

fn freePaged(allocator: std.mem.Allocator, result: Db.PagedResult) void {
    freeRecords(allocator, result.records);
}

fn expectPaths(records: []const DbRecord, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, records.len);
    for (expected, records) |exp, rec| {
        try std.testing.expectEqualStrings(exp, rec.path);
    }
}

fn hasPath(records: []const DbRecord, path: []const u8) bool {
    for (records) |r| {
        if (std.mem.eql(u8, r.path, path)) return true;
    }
    return false;
}

fn queryIndexCount(db: *Db, index_name: []const u8) !u32 {
    const handle = db.handle orelse return error.DatabaseNotOpen;
    const sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name=?;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(handle, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabasePrepareError;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, index_name.ptr, @intCast(index_name.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
    return @intCast(c.sqlite3_column_int(stmt, 0));
}

fn countRows(db: *Db) !u32 {
    const handle = db.handle orelse return error.DatabaseNotOpen;
    const sql = "SELECT COUNT(*) FROM media;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(handle, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabasePrepareError;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
    return @intCast(c.sqlite3_column_int(stmt, 0));
}

// --- Phase 1: filter regression guards ---

test "date filter includes EXIF colon timestamps (T1)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        null,
        null,
        null,
        "2026-06-01",
        "2026-06-30",
        null,
        null,
        null,
        null,
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqual(@as(u32, 2), result.total);
    try std.testing.expect(hasPath(result.records, "/photos/a.jpg"));
    try std.testing.expect(hasPath(result.records, "/photos/b.jpg"));
}

test "date filter excludes NULL create_time (T2)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        null,
        null,
        null,
        "2026-06-01",
        "2026-06-30",
        null,
        null,
        null,
        null,
    );
    defer freePaged(allocator, result);

    try std.testing.expect(!hasPath(result.records, "/photos/c.png"));
}

test "date boundary inclusivity on single day (T3)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        null,
        null,
        null,
        "2026-06-27",
        "2026-06-27",
        null,
        null,
        null,
        null,
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqual(@as(u32, 1), result.total);
    try expectPaths(result.records, &.{"/photos/a.jpg"});
}

test "size min filter (T4)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        null,
        null,
        null,
        null,
        null,
        1_073_741_824,
        null,
        null,
        null,
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqual(@as(u32, 1), result.total);
    try expectPaths(result.records, &.{"/videos/d.mp4"});
}

test "size max filter (T5)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        null,
        null,
        null,
        null,
        null,
        null,
        1_000_000,
        null,
        null,
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqual(@as(u32, 3), result.total);
    try std.testing.expect(hasPath(result.records, "/photos/a.jpg"));
    try std.testing.expect(hasPath(result.records, "/photos/c.png"));
    try std.testing.expect(hasPath(result.records, "/photos/f.tiff"));
    try std.testing.expect(!hasPath(result.records, "/videos/d.mp4"));
}

test "combined date and size filters (T6)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        null,
        null,
        null,
        "2026-06-01",
        "2026-06-30",
        400_000,
        1_000_000,
        null,
        null,
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqual(@as(u32, 1), result.total);
    try expectPaths(result.records, &.{"/photos/a.jpg"});
}

// --- Phase 2: getRecordsPaged core behavior ---

test "no filters returns full count (T7)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqual(@as(u32, 6), result.total);
    try std.testing.expectEqual(@as(usize, 6), result.records.len);
    try expectPaths(result.records, &.{
        "/photos/a.jpg",
        "/photos/b.jpg",
        "/photos/c.png",
        "/photos/f.tiff",
        "/videos/d.mp4",
        "/videos/e.mov",
    });
}

test "format filter (T8)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        null,
        "jpeg",
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqual(@as(u32, 2), result.total);
    try std.testing.expect(hasPath(result.records, "/photos/a.jpg"));
    try std.testing.expect(hasPath(result.records, "/photos/b.jpg"));
}

test "type filter image (T9)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        null,
        null,
        "image",
        null,
        null,
        null,
        null,
        null,
        null,
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqual(@as(u32, 4), result.total);
    try std.testing.expect(!hasPath(result.records, "/videos/d.mp4"));
    try std.testing.expect(!hasPath(result.records, "/videos/e.mov"));
}

test "type filter video (T10)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        null,
        null,
        "video",
        null,
        null,
        null,
        null,
        null,
        null,
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqual(@as(u32, 2), result.total);
    try expectPaths(result.records, &.{ "/videos/d.mp4", "/videos/e.mov" });
}

test "search path substring (T11)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        "photos",
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqual(@as(u32, 4), result.total);
    try std.testing.expect(!hasPath(result.records, "/videos/d.mp4"));
}

test "search format substring (T12)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        "mov",
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqual(@as(u32, 1), result.total);
    try expectPaths(result.records, &.{"/videos/e.mov"});
}

test "sort by create_time DESC (T13)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        "create_time",
        "desc",
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqual(@as(u32, 6), result.total);
    try std.testing.expectEqualStrings("/photos/a.jpg", result.records[0].path);
    try std.testing.expectEqualStrings("/photos/b.jpg", result.records[1].path);
    try std.testing.expectEqualStrings("/videos/d.mp4", result.records[2].path);
}

test "sort by size ASC (T14)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        "size",
        "asc",
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqualStrings("/photos/c.png", result.records[0].path);
}

test "pagination without duplicate paths (T15)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const page0 = try fixture.db.getRecordsPaged(
        allocator,
        2,
        0,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        "path",
        "asc",
    );
    defer freePaged(allocator, page0);

    const page1 = try fixture.db.getRecordsPaged(
        allocator,
        2,
        2,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        "path",
        "asc",
    );
    defer freePaged(allocator, page1);

    try std.testing.expectEqual(@as(u32, 6), page0.total);
    try std.testing.expectEqual(@as(u32, 6), page1.total);
    try std.testing.expectEqual(@as(usize, 2), page0.records.len);
    try std.testing.expectEqual(@as(usize, 2), page1.records.len);

    for (page0.records) |r0| {
        for (page1.records) |r1| {
            try std.testing.expect(!std.mem.eql(u8, r0.path, r1.path));
        }
    }
}

test "invalid sort key falls back to path (T16)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        "dimensions",
        "asc",
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqual(@as(u32, 6), result.total);
    try expectPaths(result.records, &.{
        "/photos/a.jpg",
        "/photos/b.jpg",
        "/photos/c.png",
        "/photos/f.tiff",
        "/videos/d.mp4",
        "/videos/e.mov",
    });
}

// --- Phase 3: other Db APIs ---

test "insertMedia and queryCache hit and miss (T17)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer tmp_ctx.cleanup();

    const path = try std.fmt.allocPrint(allocator, "{s}/cache_test.db", .{tmp_ctx.abs_path});
    defer allocator.free(path);

    var database = try Db.init(allocator, path);
    defer database.deinit();

    const record = DbRecord{
        .path = "/tmp/test.png",
        .size = 1234,
        .format = "png",
        .width = 100,
        .height = 200,
    };
    try seedRecord(&database, record, 999);

    const hit = try database.queryCache(allocator, record.path, record.size, 999);
    defer if (hit.hit) hit.json_out.deinit(allocator);
    defer if (hit.hit) allocator.free(hit.json_out.format);
    try std.testing.expect(hit.hit);
    try std.testing.expectEqual(@as(u64, 1234), hit.json_out.size);

    const size_miss = try database.queryCache(allocator, record.path, record.size + 1, 999);
    try std.testing.expect(!size_miss.hit);

    const mtime_miss = try database.queryCache(allocator, record.path, record.size, 998);
    try std.testing.expect(!mtime_miss.hit);
}

test "insertMedia upsert replaces row (T18)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer tmp_ctx.cleanup();

    const path = try std.fmt.allocPrint(allocator, "{s}/upsert_test.db", .{tmp_ctx.abs_path});
    defer allocator.free(path);

    var database = try Db.init(allocator, path);
    defer database.deinit();

    const file_path = "/photos/upsert.jpg";
    try seedRecord(&database, .{
        .path = file_path,
        .size = 100,
        .format = "jpeg",
    }, 1);
    try seedRecord(&database, .{
        .path = file_path,
        .size = 200,
        .format = "jpeg",
    }, 2);

    try std.testing.expectEqual(@as(u32, 1), try countRows(&database));

    const result = try database.getRecordsPaged(
        allocator,
        10,
        0,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqual(@as(u32, 1), result.total);
    try std.testing.expectEqual(@as(u64, 200), result.records[0].size);
}

test "getStats smoke after seeding (T19)" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const stats = try fixture.db.getStats(allocator);
    defer stats.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 6), stats.total_files);
    try std.testing.expectEqual(@as(u32, 2), stats.num_videos);
    try std.testing.expectEqual(@as(u32, 4), stats.num_images);
}

test "getStats video tiers are mutually exclusive buckets" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const stats = try fixture.db.getStats(allocator);
    defer stats.deinit(allocator);

    const vid_size_sum = stats.video_sizes.tier1 +
        stats.video_sizes.tier2 +
        stats.video_sizes.tier3 +
        stats.video_sizes.tier4 +
        stats.video_sizes.tier5;
    try std.testing.expectEqual(stats.num_videos, vid_size_sum);
    try std.testing.expectEqual(@as(u32, 0), stats.video_sizes.tier1);
    try std.testing.expectEqual(@as(u32, 1), stats.video_sizes.tier2);
    try std.testing.expectEqual(@as(u32, 1), stats.video_sizes.tier4);

    const vid_dur_sum = stats.video_durations.tier1 +
        stats.video_durations.tier2 +
        stats.video_durations.tier3 +
        stats.video_durations.tier4 +
        stats.video_durations.tier5;
    try std.testing.expectEqual(stats.num_videos, vid_dur_sum);
    try std.testing.expectEqual(@as(u32, 1), stats.video_durations.tier1);
    try std.testing.expectEqual(@as(u32, 1), stats.video_durations.tier2);

    try std.testing.expectEqual(@as(u32, 2), stats.video_formats.len);
}

test "getStatsCached returns equivalent data and reuses cache" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const fresh = try fixture.db.getStatsCached(allocator, io);
    defer fresh.deinit(allocator);
    const cached = try fixture.db.getStatsCached(allocator, io);
    defer cached.deinit(allocator);

    try std.testing.expectEqual(fresh.total_files, cached.total_files);
    try std.testing.expectEqual(fresh.total_size, cached.total_size);
    try std.testing.expect(fixture.db.stats_cache != null);
}

test "init creates expected indices (T20)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer tmp_ctx.cleanup();

    const path = try std.fmt.allocPrint(allocator, "{s}/indices_test.db", .{tmp_ctx.abs_path});
    defer allocator.free(path);

    var database = try Db.init(allocator, path);
    defer database.deinit();

    try std.testing.expectEqual(@as(u32, 1), try queryIndexCount(&database, "idx_media_size"));
    try std.testing.expectEqual(@as(u32, 1), try queryIndexCount(&database, "idx_media_create_time"));
    try std.testing.expectEqual(@as(u32, 1), try queryIndexCount(&database, "idx_media_format"));
}

test "last 7 days window with June-only fixture returns zero rows" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    const result = try fixture.db.getRecordsPaged(
        allocator,
        100,
        0,
        null,
        null,
        null,
        "2026-07-03",
        "2026-07-10",
        null,
        null,
        null,
        null,
    );
    defer freePaged(allocator, result);

    try std.testing.expectEqual(@as(u32, 0), result.total);
    try std.testing.expectEqual(@as(usize, 0), result.records.len);
}
