const std = @import("std");
const test_utils = @import("../test_utils.zig");
const Db = @import("../db.zig").Db;
const c = @import("../db.zig").c;
const DbRecord = @import("../db.zig").DbRecord;
const DbStats = @import("../db.zig").DbStats;
const migrations = @import("schema.zig").migrations;

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

    try seedFixture(&database, io);

    return .{
        .db = database,
        .tmp_ctx = tmp_ctx,
        .path = path,
    };
}

fn seedRecord(db: *Db, io: std.Io, record: DbRecord, mtime: i64) !void {
    try db.insertMedia(io, &record, mtime);
}

fn seedFixture(db: *Db, io: std.Io) !void {
    try seedRecord(db, io, .{
        .path = "/photos/a.jpg",
        .size = 500_000,
        .format = "jpeg",
        .create_time = "2026:06:27 10:15:30",
    }, 1);
    try seedRecord(db, io, .{
        .path = "/photos/b.jpg",
        .size = 2_000_000,
        .format = "jpeg",
        .create_time = "2026-06-14 12:00:00",
    }, 2);
    try seedRecord(db, io, .{
        .path = "/photos/c.png",
        .size = 50_000,
        .format = "png",
    }, 3);
    try seedRecord(db, io, .{
        .path = "/videos/d.mp4",
        .size = 1_500_000_000,
        .format = "mp4",
        .create_time = "2024-08-04 21:00:57",
        .duration_sec = 22.6,
    }, 4);
    try seedRecord(db, io, .{
        .path = "/videos/e.mov",
        .size = 24_000_000,
        .format = "mov",
        .create_time = "2022-07-31 23:52:28",
        .duration_sec = 6.6,
    }, 5);
    try seedRecord(db, io, .{
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
    const sql = "SELECT COUNT(*) FROM media_paths;";
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
    try seedRecord(&database, io, record, 999);

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
    try seedRecord(&database, io, .{
        .path = file_path,
        .size = 100,
        .format = "jpeg",
    }, 1);
    try seedRecord(&database, io, .{
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

    try std.testing.expectEqual(@as(u32, 1), try queryIndexCount(&database, "idx_paths_metadata_id"));
    try std.testing.expectEqual(@as(u32, 1), try queryIndexCount(&database, "idx_paths_size"));
    try std.testing.expectEqual(@as(u32, 0), try queryIndexCount(&database, "idx_metadata_create_time"));
    try std.testing.expectEqual(@as(u32, 1), try queryIndexCount(&database, "idx_metadata_ctime_norm"));
    try std.testing.expectEqual(@as(u32, 1), try queryIndexCount(&database, "idx_metadata_format"));
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

test "insertMedia and queryCache with has_thumbnail" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer tmp_ctx.cleanup();

    const path = try std.fmt.allocPrint(allocator, "{s}/thumb_test.db", .{tmp_ctx.abs_path});
    defer allocator.free(path);

    var database = try Db.init(allocator, path);
    defer database.deinit();

    const record = DbRecord{
        .path = "/photos/thumb_test.jpg",
        .size = 5000,
        .format = "jpeg",
        .has_thumbnail = true,
    };
    try seedRecord(&database, io, record, 123);

    const hit = try database.queryCache(allocator, record.path, record.size, 123);
    defer if (hit.hit) {
        hit.json_out.deinit(allocator);
        allocator.free(hit.json_out.format);
    };
    try std.testing.expect(hit.hit);
    try std.testing.expect(hit.json_out.has_thumbnail);

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
    try std.testing.expect(result.records[0].has_thumbnail);
}

test "updateHasThumbnail updates correctly" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer tmp_ctx.cleanup();

    const path = try std.fmt.allocPrint(allocator, "{s}/thumb_update_test.db", .{tmp_ctx.abs_path});
    defer allocator.free(path);

    var database = try Db.init(allocator, path);
    defer database.deinit();

    const record = DbRecord{
        .path = "/photos/thumb_test.jpg",
        .size = 5000,
        .format = "jpeg",
        .has_thumbnail = true,
    };
    try seedRecord(&database, io, record, 123);

    {
        const hit = try database.queryCache(allocator, record.path, record.size, 123);
        defer if (hit.hit) {
            hit.json_out.deinit(allocator);
            allocator.free(hit.json_out.format);
        };
        try std.testing.expect(hit.hit);
        try std.testing.expect(hit.json_out.has_thumbnail);
    }

    try database.updateHasThumbnail(record.path, false);

    {
        const hit = try database.queryCache(allocator, record.path, record.size, 123);
        defer if (hit.hit) {
            hit.json_out.deinit(allocator);
            allocator.free(hit.json_out.format);
        };
        try std.testing.expect(hit.hit);
        try std.testing.expect(!hit.json_out.has_thumbnail);
    }
}

test "updateHasAnimated updates correctly" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer tmp_ctx.cleanup();

    const path = try std.fmt.allocPrint(allocator, "{s}/animated_update_test.db", .{tmp_ctx.abs_path});
    defer allocator.free(path);

    var database = try Db.init(allocator, path);
    defer database.deinit();

    // Insert a video record with has_animated = true
    const record = DbRecord{
        .path = "/videos/preview_test.mp4",
        .size = 10_000_000,
        .format = "mp4",
        .duration_sec = 30.0,
        .has_thumbnail = true,
        .has_animated = true,
    };
    try seedRecord(&database, io, record, 456);

    {
        const hit = try database.queryCache(allocator, record.path, record.size, 456);
        defer if (hit.hit) {
            hit.json_out.deinit(allocator);
            allocator.free(hit.json_out.format);
        };
        try std.testing.expect(hit.hit);
        try std.testing.expect(hit.json_out.has_animated);
    }

    // Simulate cache-heal: mark the animated preview as missing
    try database.updateHasAnimated(record.path, false);

    {
        const hit = try database.queryCache(allocator, record.path, record.size, 456);
        defer if (hit.hit) {
            hit.json_out.deinit(allocator);
            allocator.free(hit.json_out.format);
        };
        try std.testing.expect(hit.hit);
        try std.testing.expect(!hit.json_out.has_animated);
        // has_thumbnail should be unaffected
        try std.testing.expect(hit.json_out.has_thumbnail);
    }
}

test "has_animated round-trips through insertMedia and queryCache" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer tmp_ctx.cleanup();

    const path = try std.fmt.allocPrint(allocator, "{s}/has_animated_rt.db", .{tmp_ctx.abs_path});
    defer allocator.free(path);

    var database = try Db.init(allocator, path);
    defer database.deinit();

    const rec_with = DbRecord{
        .path = "/videos/anim.mp4",
        .size = 5_000_000,
        .format = "mp4",
        .duration_sec = 10.0,
        .has_thumbnail = true,
        .has_animated = true,
    };
    const rec_without = DbRecord{
        .path = "/videos/nonanim.mp4",
        .size = 3_000_000,
        .format = "mp4",
        .duration_sec = 5.0,
        .has_thumbnail = true,
        .has_animated = false,
    };
    try seedRecord(&database, io, rec_with, 1);
    try seedRecord(&database, io, rec_without, 2);

    const hit_with = try database.queryCache(allocator, rec_with.path, rec_with.size, 1);
    defer if (hit_with.hit) {
        hit_with.json_out.deinit(allocator);
        allocator.free(hit_with.json_out.format);
    };
    try std.testing.expect(hit_with.hit);
    try std.testing.expect(hit_with.json_out.has_animated);

    const hit_without = try database.queryCache(allocator, rec_without.path, rec_without.size, 2);
    defer if (hit_without.hit) {
        hit_without.json_out.deinit(allocator);
        allocator.free(hit_without.json_out.format);
    };
    try std.testing.expect(hit_without.hit);
    try std.testing.expect(!hit_without.json_out.has_animated);
}

test "database relational migration moves legacy data" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer tmp_ctx.cleanup();

    const path = try std.fmt.allocPrint(allocator, "{s}/migration_legacy.db", .{tmp_ctx.abs_path});
    defer allocator.free(path);

    // 1. Manually construct version 1 schema & insert legacy records
    {
        var handle: ?*c.sqlite3 = null;
        const path_c = try allocator.dupeZ(u8, path);
        defer allocator.free(path_c);
        const rc = c.sqlite3_open(path_c, &handle);
        try std.testing.expectEqual(c.SQLITE_OK, rc);
        defer _ = c.sqlite3_close(handle);

        const version1_sql = migrations[0];
        var err_msg: [*c]u8 = null;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(handle, version1_sql.ptr, null, null, &err_msg));
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(handle, "PRAGMA user_version = 1;", null, null, null));

        // Insert legacy data
        const insert_sql = "INSERT INTO media (path, size, mtime, format, width, height) VALUES ('/legacy.jpg', 12345, 98765, 'jpeg', 800, 600);";
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(handle, insert_sql, null, null, null));
    }

    // 2. Open via Db.init, which should automatically migrate version 1 to target version (version 2)
    var database = try Db.init(allocator, path);
    defer database.deinit();

    // 3. Verify it migrated and data is queryable
    const cache_res = try database.queryCache(allocator, "/legacy.jpg", 12345, 98765);
    defer if (cache_res.hit) {
        cache_res.json_out.deinit(allocator);
        allocator.free(cache_res.json_out.format);
    };
    try std.testing.expect(cache_res.hit);
    try std.testing.expectEqualStrings("jpeg", cache_res.json_out.format);
    try std.testing.expectEqual(@as(?u32, 800), cache_res.json_out.width);
    try std.testing.expectEqual(@as(?u32, 600), cache_res.json_out.height);
}

test "orphan metadata is cleaned up by triggers on delete or update" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer tmp_ctx.cleanup();

    const path = try std.fmt.allocPrint(allocator, "{s}/trigger_test.db", .{tmp_ctx.abs_path});
    defer allocator.free(path);

    var database = try Db.init(allocator, path);
    defer database.deinit();

    // Insert two duplicate files (same content hash, different paths)
    const rec1 = DbRecord{
        .path = "/photos/1.jpg",
        .size = 100,
        .format = "jpeg",
        .file_hash = "abc",
    };
    const rec2 = DbRecord{
        .path = "/photos/2.jpg",
        .size = 100,
        .format = "jpeg",
        .file_hash = "abc",
    };

    try database.insertMedia(io, &rec1, 10);
    try database.insertMedia(io, &rec2, 10);

    // Verify metadata row count is 1
    {
        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(database.handle, "SELECT COUNT(*) FROM media_metadata;", -1, &stmt, null);
        defer _ = c.sqlite3_finalize(stmt);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
        try std.testing.expectEqual(@as(i32, 1), c.sqlite3_column_int(stmt, 0));
    }

    // Delete one path, metadata should NOT be deleted (still referenced by path 2)
    _ = c.sqlite3_exec(database.handle, "DELETE FROM media_paths WHERE path = '/photos/1.jpg';", null, null, null);
    {
        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(database.handle, "SELECT COUNT(*) FROM media_metadata;", -1, &stmt, null);
        defer _ = c.sqlite3_finalize(stmt);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
        try std.testing.expectEqual(@as(i32, 1), c.sqlite3_column_int(stmt, 0));
    }

    // Delete second path, metadata should be deleted (orphan cleanup trigger)
    _ = c.sqlite3_exec(database.handle, "DELETE FROM media_paths WHERE path = '/photos/2.jpg';", null, null, null);
    {
        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(database.handle, "SELECT COUNT(*) FROM media_metadata;", -1, &stmt, null);
        defer _ = c.sqlite3_finalize(stmt);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
        try std.testing.expectEqual(@as(i32, 0), c.sqlite3_column_int(stmt, 0));
    }
}

test "database migration from version 2 to 3" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_ctx = try test_utils.TempDirContext.init(allocator, io);
    defer tmp_ctx.cleanup();

    const path = try std.fmt.allocPrint(allocator, "{s}/migration_v2_v3.db", .{tmp_ctx.abs_path});
    defer allocator.free(path);

    // 1. Manually construct version 2 schema
    {
        var handle: ?*c.sqlite3 = null;
        const path_c = try allocator.dupeZ(u8, path);
        defer allocator.free(path_c);
        const rc = c.sqlite3_open(path_c, &handle);
        try std.testing.expectEqual(c.SQLITE_OK, rc);
        defer _ = c.sqlite3_close(handle);

        var err_msg: [*c]u8 = null;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(handle, migrations[0].ptr, null, null, &err_msg));
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(handle, migrations[1].ptr, null, null, &err_msg));
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(handle, "PRAGMA user_version = 2;", null, null, null));
    }

    // 2. Open via Db.init, which should automatically migrate version 2 to version 3
    var database = try Db.init(allocator, path);
    defer database.deinit();

    // 3. Verify it migrated and indices are correct
    try std.testing.expectEqual(@as(u32, 0), try queryIndexCount(&database, "idx_metadata_create_time"));
    try std.testing.expectEqual(@as(u32, 1), try queryIndexCount(&database, "idx_metadata_ctime_norm"));
}

test "Db.pathExists checks if a path is in database" {
    const allocator = std.testing.allocator;
    var fixture = try testDb(allocator);
    defer fixture.deinit(allocator);

    try std.testing.expectEqual(true, try fixture.db.pathExists("/photos/a.jpg"));
    try std.testing.expectEqual(true, try fixture.db.pathExists("/photos/c.png"));
    try std.testing.expectEqual(false, try fixture.db.pathExists("/nonexistent/file.png"));
}
