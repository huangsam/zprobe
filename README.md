# zprobe

A lightweight, zero-dependency command-line utility and library written in Zig for recursively scanning directories and extracting dimensions, format, and metadata directly from image and video file headers.

Most media metadata tools are bloated and not built for constrained environments like a NAS or Raspberry Pi. `zprobe` takes a deliberate approach — reading raw binary headers, managing memory explicitly, and compiling to any target without fighting a toolchain. The result is a single self-contained binary with no runtime dependencies, in the spirit of classic Unix utilities like `ls` or `grep`.

See the [User Guide](USERGUIDE.md) and [Developer & Agent Guide](AGENTS.md) to dive deeper.

## Usage

```bash
# Scan multiple directories and display metadata
zprobe /path/to/photo /path/to/video

# Scan with SQLite metadata caching enabled
zprobe --db /path/to/cache.db /path/to/photo

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
