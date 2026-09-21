# Engineering Learnings: Memory Management & Arena Lifecycles

## Context & The Concurrency Challenge

`zprobe` is built to scan tens or hundreds of thousands of files across multi-threaded worker pools (typically clamped between 8 and 16 worker threads depending on CPU core count).

Each media file requires transient memory for header buffers, decoded EXIF strings, hash digests, and path slices.

In a naive multi-threaded implementation relying on global heap allocation, this workload induces two major bottlenecks:

1. **Global Allocator Lock Contention**: Worker threads contend for the global heap mutex on every micro-allocation.
2. **Leak Hazards on Failure**: If parsing aborts early on malformed data, tracking and freeing every partial allocation introduces memory leaks and cognitive overhead.

This document details the architectural patterns `zprobe` uses to eliminate these issues.

---

## The Per-Task Arena Pattern

In [`src/cli/worker_pool.zig`](file:///Users/samhuang/Playground/projects/zprobe/src/cli/worker_pool.zig#L361-L364), each worker thread instantiates an `ArenaAllocator` scoped strictly to the lifecycle of a single file:

```zig
pub fn processFile(c_ctx: WorkerContext, entry: media_scan.ScanEntry, is_video: bool) !void {
    const file = std.Io.Dir.openFileAbsolute(c_ctx.io, entry.path, .{ .mode = .read_only }) catch |err| { ... };
    defer std.Io.File.close(file, c_ctx.io);

    ...
    // Per-file arena allocator initialized on top of the worker's parent allocator
    var arena = std.heap.ArenaAllocator.init(c_ctx.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // 1. Try DB cache lookup
    if (queryCacheRecord(c_ctx, entry.path, fsize, mtime, is_video, arena_allocator, &force_regen)) |record| {
        try cli.output_formatter.printMetadataRecord(c_ctx, record, fsize);
        return;
    }

    // 2. Compute fast hash
    const file_hash = hashing.computeFastHash(c_ctx.io, arena_allocator, entry.path) catch null;

    // 3. Parse headers (allocates EXIF strings, rational numbers)
    const record = parseMediaFile(c_ctx, entry.path, fsize, is_video, file_hash, arena_allocator) catch {
        return; // All allocated memory is freed automatically by defer arena.deinit()
    };

    // 4. Save to SQLite and format output
    saveRecordToDb(c_ctx, &record, mtime);
    try cli.output_formatter.printMetadataRecord(c_ctx, record, fsize);
}
```

---

## Key Benefits of This Architecture

### 1. $O(1)$ Batch Deallocation

Instead of tracking and freeing individual strings and buffers, the entire arena memory pool is destroyed at once when `processFile` exits:

```zig
defer arena.deinit();
```

All memory blocks allocated for that file are returned to the backing allocator in one batch, reducing thousands of individual free operations to a single pointer reset.

### 2. Elimination of Lock Contention

Because `ArenaAllocator` requests memory in large chunks (e.g. 4KB–64KB blocks) from the backing allocator, worker threads rarely touch the underlying parent allocator. Micro-allocations occur bump-pointer style within the thread's private arena without taking locks.

### 3. Leak-Free Failure Modes

When parsing corrupted or truncated files, functions return error sets via Zig's `try` or `catch return`:

```zig
const record = parseMediaFile(...) catch return;
```

No manual cleanup code is needed. When the scope exits early on an error, `defer arena.deinit()` fires automatically, completely preventing memory leaks by construction.

---

## Explicit Allocator Discipline

Zig does not have a hidden global allocator. Every function that requires heap memory must accept an explicit `std.mem.Allocator` argument.

In `zprobe`, this enforces a clean separation of memory lifecycles:

### 1. Transient Lifetime (Arena Allocator)

Passed to format parsers (`parseJpegFile`, `parseIfd`, `getVideoMetadata`) and string decoders (`readAscii`). These allocations only need to live as long as the file is being parsed.

```zig
pub fn readAscii(self: *ByteReader, allocator: std.mem.Allocator, count: u32) ![]const u8 {
    ...
    const result = try allocator.alloc(u8, len);
    @memcpy(result, raw[0..len]);
    return result;
}
```

### 2. Long-Lived Lifetime (Parent Allocator)

Passed to long-standing structures, such as the `media_scan.ScanEntry` directory list, SQLite statement handles, and the HTTP server's thread pool.

---

## Short-Lived Caching Arenas

The same arena pattern is applied to cached calculations that expire periodically. For example, in `src/core/db.zig` and `src/core/db/query.zig`, the aggregated statistics query (`DbStats`) is cached with a 2-second Time-To-Live (TTL):

```zig
pub const Db = struct {
    ...
    stats_cache: ?DbStats = null,
    stats_cache_expires_ns: i96 = 0,
    stats_cache_arena: std.heap.ArenaAllocator,
    ...
};
```

When the stats cache expires:

1. `stats_cache_arena.deinit()` releases all previous strings and format breakdowns.
2. The arena is re-initialized for the new computation.
3. Fresh statistics are computed and cached, avoiding memory accumulation over long-running server sessions.

---

## Summary of Memory Principles

1. **Scope arenas to the task boundary**: Use a dedicated `ArenaAllocator` per unit of work (e.g., per media file or per HTTP request).
2. **Rely on `defer arena.deinit()` for cleanup**: Ensure both success and error exit paths cleanly release all allocated memory.
3. **Keep parsers agnostic of allocation strategy**: Format parsers should simply accept `allocator: std.mem.Allocator` without knowing whether it is a general-purpose allocator or an arena.
4. **Avoid passing arenas to long-lived consumers**: If data from an arena must outlive the task (e.g., storing in a long-lived database), copy it or serialize it before the arena is destroyed.
