# zprobe

A lightweight, zero-dependency command-line utility and library written in Zig for recursively scanning directories and extracting dimensions, format, and metadata directly from image and video file headers.

Most media metadata tools are either bloated daemons, depend on heavyweight runtimes, or aren't built for constrained environments like a NAS or Raspberry Pi. `zprobe` takes a deliberate approach — reading raw binary headers, managing memory explicitly, and compiling to any target without fighting a toolchain.

See the [User Guide](USERGUIDE.md) and [Developer & Agent Guide](AGENTS.md) for next steps.

## Supported Formats & Metadata

### Images

| Format | Dimensions | Orientation | Metadata                                   |
| ------ | ---------- | ----------- | ------------------------------------------ |
| JPEG   | ✓          | ✓           | EXIF: Capture Date, Camera Make/Model, GPS |
| PNG    | ✓          | ✗           | None                                       |
| GIF    | ✓          | ✗           | None                                       |
| BMP    | ✓          | ✗           | None                                       |
| WebP   | ✓          | ✓           | EXIF: Capture Date, GPS                    |
| TIFF   | ✓          | ✓           | EXIF: Capture Date, Camera Make/Model, GPS |

### Videos

| Format | Dimensions | Duration | Orientation | Metadata                |
| ------ | ---------- | -------- | ----------- | ----------------------- |
| MP4    | ✓          | ✓        | ✓           | Creation Date, Rotation |
| WebM   | ✓          | ✓        | ✗           | None                    |
| MKV    | ✓          | ✓        | ✗           | None                    |
