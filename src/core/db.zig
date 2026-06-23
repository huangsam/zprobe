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
};
