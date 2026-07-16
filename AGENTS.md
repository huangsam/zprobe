# Developer & Agent Guide: Project Architecture

This document details the internal design, directory layout, parsing flow, and coding principles of `zprobe`. It serves as a guide for developer agents and human contributors working on or extending this codebase.

## Project Architecture

`zprobe` scans a target directory recursively for media files, parses their binary headers, and outputs metadata (dimensions, file formats, and sizes) as plain text or structured JSON.

### Directory Structure

```text
src/
├── core/       # Byte reader, SQLite cache interface
├── crawler/    # Filesystem scanner and crawler logic
├── formats/    # Image and video binary header parsers
│   ├── images/ # Parsers for BMP, GIF, JPEG, PNG, TIFF, and WebP
│   └── videos/ # Parsers for MP4 (ISOBMFF) and WebM/MKV (EBML)
└── web/        # Embedded dashboard assets
```

### Parse Flow

```mermaid
flowchart TD
    Path(["Directory Path"]) --> Scan["media_scan.scan()"]
    Scan -->|"Finds media files"| File["Identify Format (Magic Bytes)"]

    File -->|"PNG, GIF, BMP"| MemImg["parseFile() (In-Memory)
    Reads header and extracts layout"]

    File -->|"JPEG, WebP, TIFF"| StreamImg["parseFile() (Streaming/Chunks)
    Walks chunks/segments & parses EXIF tags"]

    File -->|"MP4 Video"| MP4["getVideoMetadata() (MP4 Boxes)
    Parses mvhd (duration) & tkhd (orientation)"]

    File -->|"WebM or MKV"| EBML["getVideoMetadata() (EBML Elements)
    Decodes VINTs to find tracks & duration"]

    MemImg --> Out["Output: Dimensions, Format, Size, EXIF Metadata"]
    StreamImg --> Out
    MP4 --> Out
    EBML --> Out
```

### Key Design Principles

1. **Explicit Memory Allocation**: All heap allocation is explicit. If any step fails during parsing or directory iteration, Zig's `errdefer` mechanism ensures allocated paths and buffers are completely freed.
2. **Bounds Protection**: All parsing leverages `ByteReader` which performs bounds checking on every read/skip operation, avoiding vulnerabilities like buffer overflows on malformed inputs.
3. **Zero-Copy / Small Buffer Parsing**: Fixed-header formats (PNG/GIF/BMP) are parsed using a single small read. Streaming formats (JPEG, MP4, EBML) are traversed dynamically using positional reads (`readPositionalAll`) to avoid loading large media streams into memory.
4. **Concurrent I/O Parallelization**: Scanning and metadata parsing are separated into a fast, sequential path scanner followed by a concurrent worker thread pool. The pool size dynamically clamps between 8 and 16 based on core count to parallelize disk seeks, but can be overridden by users using `-j`/`--concurrency`. Output is synchronized using mutexes, and allocations are isolated in per-task arena allocators to eliminate global heap lock contention.
5. **SQLite Concurrency & Aggregations**: The cache database runs in Write-Ahead Log (`WAL`) mode with a busy timeout of 5 seconds to ensure the crawler CLI and dashboard server can safely interface concurrently. The stats dashboard is populated using single-pass grouping queries computed inside SQLite and cached in-memory with a short TTL (2 seconds) to avoid transferring large collections or running redundant scans.
6. **Thread Pool Web Handlers**: Incoming TCP connections are dispatched to a pre-allocated worker thread pool (recycling threads based on CPU count) to eliminate connection thread spawning overhead. Static assets are served asynchronously, while SQLite read queries are parallelized using a shared Read-Write Lock (`RwLock`) on the database handle, ensuring optimal concurrency for concurrent dashboard readers.
7. **Relational Schema & Decoupled Caching**: Caching is structured relationally using `media_metadata` (representing unique media details keyed by `file_hash`) and `media_paths` (physical path references). SQLite foreign keys are enforced (`PRAGMA foreign_keys = ON;`), and custom cascading triggers (`cleanup_orphan_metadata` and `cleanup_orphan_metadata_update`) clean up orphaned metadata rows automatically when a referencing file path is deleted or changed.
8. **Fast Content Hashing & Pruning**: Duplicate detection uses a fast content-only hash: `Hash(File Size || First 100KB || Last 100KB)` for files $\ge 2\text{ MB}$, or sequential reading for smaller files. When `--prune` is invoked, the crawler performs transactional matching to identify and delete stale paths in the target directories, ensuring the database stays synchronized with the filesystem.
9. **Optional HTTP Basic Authentication**: Basic authentication is supported optionally via `ZPROBE_AUTH_USER` and `ZPROBE_AUTH_PASS` environment variables. The request interceptor parses the `Authorization` header and decodes credentials on the stack (zero-heap-allocation, memory-safe, OOM-safe) to authorize dashboard and API access.
10. **Static Table Layout for Resize Performance**: The media catalog table uses `table-layout: fixed` with explicit percentage widths on each `<th>` (`#th-path`, `#th-date`, `#th-size`, `#th-format`, `#th-dimensions`). This is a critical rendering performance constraint. The default `table-layout: auto` causes the browser to scan every cell's content on every pixel of a window resize to recompute column widths, which cascades into a full-page layout invalidation (visible as a full-viewport green paint flash in Chrome DevTools). File name and path cells use `text-overflow: ellipsis` with `white-space: nowrap` to keep row heights static during resizes. Do not revert these rules to `table-layout: auto`, `overflow-wrap: anywhere`, or `clamp()`-based cell padding.
11. **Path-Based Preview Generation & Aligned Formats**: Previews and thumbnails are derived via path-based hashing: `sha256(original_path)` determines both the JPEG poster (`.jpg`) and the animated WebP preview (`.webp`). These live under `.zprobe_thumbnails`. The definition of what constitutes a video is strictly unified between the crawler scanner extensions, the SQL database query predicates, and the frontend JS router (`mp4, m4v, webm, mkv, mov, avi, wmv, flv`).
