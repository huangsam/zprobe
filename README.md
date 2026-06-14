# zprobe

A lightweight, zero-dependency command-line utility and library written in Zig for recursively scanning directories and extracting dimensions, format, and metadata directly from image and video file headers.

Most media metadata tools are bloated and not built for constrained environments like a NAS or Raspberry Pi. `zprobe` takes a deliberate approach — reading raw binary headers, managing memory explicitly, and compiling to any target without fighting a toolchain. The result is a single self-contained binary with no runtime dependencies, in the spirit of classic Unix utilities like `ls` or `grep`.

See the [User Guide](USERGUIDE.md) and [Developer & Agent Guide](AGENTS.md) to dive deeper.

## Supported Formats

| Format | Dimensions | Duration | Orientation |
| ------ | ---------- | -------- | ----------- |
| JPEG   | ✓          | ✗        | ✓           |
| PNG    | ✓          | ✗        | ✗           |
| GIF    | ✓          | ✗        | ✗           |
| BMP    | ✓          | ✗        | ✗           |
| WebP   | ✓          | ✗        | ✓           |
| TIFF   | ✓          | ✗        | ✓           |
| MP4    | ✓          | ✓        | ✓           |
| WebM   | ✓          | ✓        | ✗           |
| MKV    | ✓          | ✓        | ✗           |

For detailed metadata capabilities, see the [User Guide](USERGUIDE.md).
