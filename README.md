# zprobe: Media Scanner and Metadata Parser

A lightweight, zero-dependency command-line utility and library written in Zig for recursively scanning directories and extracting dimensions, format, and metadata directly from image and video file headers.

Most media metadata tools are either bloated daemons, depend on heavyweight runtimes, or aren't built for constrained environments like a NAS or Raspberry Pi. `zprobe` takes a deliberate approach — reading raw binary headers, managing memory explicitly, and compiling to any target without fighting a toolchain.

See the [User Guide](USERGUIDE.md) and [Developer & Agent Guide](AGENTS.md) for next steps.

## Supported Formats & Metadata

| Media Category | File Formats                                                     | Extracted Metadata                                                                                                  |
| :------------- | :--------------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------ |
| **Images**     | **JPEG**, **PNG**, **GIF**, **BMP**, **WebP**, **TIFF**          | Dimensions (Width/Height), Format, Orientation, Capture Date/Time, Camera Make/Model, GPS Latitude/Longitude (EXIF) |
| **Videos**     | **MP4** (including `.mov`, `.m4v`), **WebM**, **Matroska (MKV)** | Dimensions (Width/Height), Format, Duration (seconds), Orientation/Rotation, Creation Date/Time                     |
