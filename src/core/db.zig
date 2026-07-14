//! SQLite Database caching and media cataloging module.
//!
//! Encapsulates schema definition, cache queries, media record inserts,
//! and bulk transactional batching.

const std = @import("std");
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const types = @import("db/types.zig");
pub const schema = @import("db/schema.zig");
pub const query = @import("db/query.zig");

// Re-export structural types
pub const DbRecord = types.DbRecord;
pub const CacheResult = types.CacheResult;
pub const DbStats = types.DbStats;
pub const PagedResult = types.PagedResult;

/// Manager wrapping SQLite database connection and prepared statements.
pub const Db = struct {
    allocator: std.mem.Allocator,
    db_path: []const u8,
    handle: ?*c.sqlite3,
    query_stmt: ?*c.sqlite3_stmt = null,
    rwlock: std.Io.RwLock = std.Io.RwLock.init,
    stats_cache: ?DbStats = null,
    stats_cache_expires_ns: i96 = 0,
    stats_cache_arena: std.heap.ArenaAllocator,
    paged_stmt_cache: types.PagedStmtCache = .{},
    paged_stmt_cache_arena: std.heap.ArenaAllocator,

    pub const PagedResult = types.PagedResult;

    // Lifecycle and locking (implemented in schema.zig)
    pub const init = schema.init;
    pub const deinit = schema.deinit;
    pub const lockRead = schema.lockRead;
    pub const unlockRead = schema.unlockRead;
    pub const lockWrite = schema.lockWrite;
    pub const unlockWrite = schema.unlockWrite;
    pub const beginTransaction = schema.beginTransaction;
    pub const commitTransaction = schema.commitTransaction;

    // Queries and operations (implemented in query.zig)
    pub const queryCache = query.queryCache;
    pub const queryMetadataByHash = query.queryMetadataByHash;
    pub const insertMedia = query.insertMedia;
    pub const updateHasThumbnail = query.updateHasThumbnail;
    pub const deletePath = query.deletePath;
    pub const pruneStalePaths = query.pruneStalePaths;
    pub const getAllRecords = query.getAllRecords;
    pub const freeAllRecords = query.freeAllRecords;
    pub const getStats = query.getStats;
    pub const getStatsCached = query.getStatsCached;
    pub const getRecordsPaged = query.getRecordsPaged;

    // Internal helper methods used by query.zig
    pub const getOrPreparePagedStmt = query.getOrPreparePagedStmt;
    pub const invalidateStatsCache = query.invalidateStatsCache;
};

// Re-export tests by importing the test file so that `zig test` runs them
test {
    _ = @import("db/test.zig");
}
