# zprobe

[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/huangsam/zprobe/ci.yml)](https://github.com/huangsam/zprobe/actions)
[![License](https://img.shields.io/github/license/huangsam/zprobe)](https://github.com/huangsam/zprobe/blob/main/LICENSE)

A lightweight, zero-dependency media toolkit written in Zig for recursively scanning directories and extracting metadata directly from image and video file headers.

The project ships as two focused binaries: `zprobe` for fast CLI scanning and metadata extraction, and `zprobe-server` for browsing cached results through a local web dashboard.

Unlike bloated media indexers, `zprobe` is built specifically for constrained environments like a NAS or Raspberry Pi. By reading raw binary headers and leveraging SQLite for caching, it enables near-instant incremental scans and visual filtering without the heavy overhead. The result is two self-contained binaries, in the spirit of classic Unix utilities like `ls` or `grep`.

See the [User Guide](USERGUIDE.md) and [Developer & Agent Guide](AGENTS.md) to dive deeper.

## Dashboard Preview

![zprobe dashboard showing scanned files, catalog size, and media filters](images/dashboard.png)

> Live dashboard view backed by the SQLite metadata cache, with instant search and extensive filters for format, media type, date, and file size.

## Usage

```bash
# Scan multiple directories and display metadata
zprobe /path/to/photo /path/to/video

# Scan with SQLite metadata caching enabled
zprobe --db /path/to/cache.db /path/to/photo

# Scan and prune stale database entries for deleted files in the target directories
zprobe --db /path/to/cache.db --prune /path/to/photo

# Start the dashboard web server (with optional basic authentication)
ZPROBE_AUTH_USER=admin ZPROBE_AUTH_PASS=password zprobe-server --port 8080 --db /path/to/cache.db

# Show CLI options and supported formats
zprobe --help
```

## Supported Formats

| Format | Dimensions | Duration | Orientation |
| ------ | ---------- | -------- | ----------- |
| JPEG   | Yes        | No       | Yes         |
| PNG    | Yes        | No       | No          |
| GIF    | Yes        | No       | No          |
| BMP    | Yes        | No       | No          |
| WebP   | Yes        | No       | Yes         |
| TIFF   | Yes        | No       | Yes         |
| AVIF   | Yes        | No       | No          |
| ICO    | Yes        | No       | No          |
| JXL    | Yes        | No       | No          |
| MP4    | Yes        | Yes      | Yes         |
| MOV    | Yes        | Yes      | Yes         |
| WebM   | Yes        | Yes      | No          |
| MKV    | Yes        | Yes      | No          |
