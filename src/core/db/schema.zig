const std = @import("std");
const Db = @import("../db.zig").Db;
const c = @import("../db.zig").c;

fn getDbUserVersion(handle: *c.sqlite3) !i32 {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "PRAGMA user_version;";
    if (c.sqlite3_prepare_v2(handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.DatabasePrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        return @intCast(c.sqlite3_column_int(stmt, 0));
    }
    return 0;
}

fn setDbUserVersion(handle: *c.sqlite3, version: i32) !void {
    var buf: [64]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf, "PRAGMA user_version = {d};\x00", .{version});
    var err_msg: [*c]u8 = null;
    if (c.sqlite3_exec(handle, sql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
        if (err_msg) |msg| {
            std.debug.print("Failed to set user_version: {s}\n", .{msg});
            c.sqlite3_free(msg);
        }
        return error.DatabaseExecuteError;
    }
}

pub const migrations = [_][]const u8{
    // Version 1: Initial legacy schema
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
    \\    duration_sec REAL,
    \\    has_thumbnail INTEGER DEFAULT 0
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_media_size ON media(size);
    \\CREATE INDEX IF NOT EXISTS idx_media_create_time ON media(create_time);
    \\CREATE INDEX IF NOT EXISTS idx_media_format ON media(format);
    ,
    // Version 2: Relational Schema & Legacy Data Migration
    \\CREATE TABLE IF NOT EXISTS media_metadata (
    \\    id INTEGER PRIMARY KEY,
    \\    file_hash TEXT UNIQUE,
    \\    format TEXT,
    \\    width INTEGER,
    \\    height INTEGER,
    \\    orientation INTEGER,
    \\    create_time TEXT,
    \\    camera_make TEXT,
    \\    camera_model TEXT,
    \\    gps_latitude REAL,
    \\    gps_longitude REAL,
    \\    duration_sec REAL,
    \\    has_thumbnail INTEGER DEFAULT 0
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS media_paths (
    \\    path TEXT PRIMARY KEY,
    \\    size INTEGER,
    \\    mtime INTEGER,
    \\    metadata_id INTEGER NOT NULL,
    \\    FOREIGN KEY(metadata_id) REFERENCES media_metadata(id) ON DELETE CASCADE
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_paths_metadata_id ON media_paths(metadata_id);
    \\CREATE INDEX IF NOT EXISTS idx_paths_size ON media_paths(size);
    \\CREATE INDEX IF NOT EXISTS idx_metadata_create_time ON media_metadata(create_time);
    \\CREATE INDEX IF NOT EXISTS idx_metadata_format ON media_metadata(format);
    \\
    \\CREATE TRIGGER IF NOT EXISTS cleanup_orphan_metadata
    \\AFTER DELETE ON media_paths
    \\BEGIN
    \\    DELETE FROM media_metadata
    \\    WHERE id = OLD.metadata_id
    \\      AND NOT EXISTS (SELECT 1 FROM media_paths WHERE metadata_id = OLD.metadata_id);
    \\END;
    \\
    \\CREATE TRIGGER IF NOT EXISTS cleanup_orphan_metadata_update
    \\AFTER UPDATE OF metadata_id ON media_paths
    \\BEGIN
    \\    DELETE FROM media_metadata
    \\    WHERE id = OLD.metadata_id
    \\      AND NOT EXISTS (SELECT 1 FROM media_paths WHERE metadata_id = OLD.metadata_id);
    \\END;
    \\
    \\-- Migrate legacy data
    \\INSERT OR IGNORE INTO media_metadata (
    \\    file_hash, format, width, height, orientation, create_time,
    \\    camera_make, camera_model, gps_latitude, gps_longitude, duration_sec, has_thumbnail
    \\)
    \\SELECT
    \\    (size || '_' || mtime || '_' || COALESCE(format, '') || '_' || COALESCE(width, 0) || '_' || COALESCE(height, 0)),
    \\    format, width, height, orientation, create_time,
    \\    camera_make, camera_model, gps_latitude, gps_longitude, duration_sec, has_thumbnail
    \\FROM media;
    \\
    \\INSERT OR IGNORE INTO media_paths (path, size, mtime, metadata_id)
    \\SELECT m.path, m.size, m.mtime, mm.id
    \\FROM media m
    \\JOIN media_metadata mm ON mm.file_hash = (m.size || '_' || m.mtime || '_' || COALESCE(m.format, '') || '_' || COALESCE(m.width, 0) || '_' || COALESCE(m.height, 0));
    \\
    \\DROP TABLE media;
    ,
    // Version 3: Expression index for normalized create_time. MUST stay byte-identical to normalized_create_time_expr in src/core/db/query.zig (without table alias)
    \\CREATE INDEX IF NOT EXISTS idx_metadata_ctime_norm
    \\ON media_metadata(
    \\    REPLACE(SUBSTR(create_time, 1, 10), ':', '-') || SUBSTR(create_time, 11)
    \\);
    \\DROP INDEX IF EXISTS idx_metadata_create_time;
    ,
    // Version 4: Add has_animated column to track per-content-hash animated GIF previews
    \\ALTER TABLE media_metadata ADD COLUMN has_animated INTEGER DEFAULT 0;
};

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

    // Enable WAL mode, busy timeout, and foreign keys
    _ = c.sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", null, null, null);
    _ = c.sqlite3_exec(handle, "PRAGMA busy_timeout=5000;", null, null, null);
    _ = c.sqlite3_exec(handle, "PRAGMA foreign_keys=ON;", null, null, null);

    // Programmatic sequential migrations under exclusive lock
    _ = c.sqlite3_exec(handle, "BEGIN IMMEDIATE TRANSACTION;", null, null, null);
    var current_version = getDbUserVersion(handle.?) catch |err| {
        _ = c.sqlite3_exec(handle, "ROLLBACK;", null, null, null);
        return err;
    };

    const target_version = migrations.len;
    if (current_version < target_version) {
        if (!@import("builtin").is_test) {
            std.debug.print("Upgrading database schema from version {d} to {d}...\n", .{ current_version, target_version });
        }
        while (current_version < target_version) {
            const migration_sql = migrations[@intCast(current_version)];
            var err_msg: [*c]u8 = null;
            const exec_rc = c.sqlite3_exec(handle, migration_sql.ptr, null, null, &err_msg);
            if (exec_rc != c.SQLITE_OK) {
                if (err_msg) |msg| {
                    std.debug.print("Migration error at version {d}: {s}\n", .{ current_version + 1, msg });
                    c.sqlite3_free(msg);
                }
                _ = c.sqlite3_exec(handle, "ROLLBACK;", null, null, null);
                return error.DatabaseSchemaError;
            }
            current_version += 1;
            setDbUserVersion(handle.?, current_version) catch |err| {
                _ = c.sqlite3_exec(handle, "ROLLBACK;", null, null, null);
                return err;
            };
        }
    }
    _ = c.sqlite3_exec(handle, "COMMIT TRANSACTION;", null, null, null);

    const dup_path = try allocator.dupe(u8, db_path);
    errdefer {
        allocator.free(dup_path);
    }

    return Db{
        .allocator = allocator,
        .db_path = dup_path,
        .handle = handle,
        .stats_cache_arena = std.heap.ArenaAllocator.init(allocator),
    };
}

/// Finalize statements and close connection.
pub fn deinit(self: *Db) void {
    self.allocator.free(self.db_path);
    self.stats_cache_arena.deinit();
    if (self.handle) |h| _ = c.sqlite3_close(h);
    self.handle = null;
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

/// Begin bulk transaction.
pub fn beginTransaction(self: *Db) void {
    if (self.handle) |h| {
        _ = c.sqlite3_exec(h, "BEGIN TRANSACTION;", null, null, null);
    }
}

/// Commit transaction.
pub fn commitTransaction(self: *Db, io: std.Io) void {
    if (self.handle) |h| {
        _ = c.sqlite3_exec(h, "COMMIT TRANSACTION;", null, null, null);
        self.invalidateStatsCache(io);
    }
}
