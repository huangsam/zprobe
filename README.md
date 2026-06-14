# zprobe: Media Scanner and Metadata Parser

A lightweight, zero-dependency command-line utility and library written in Zig for recursively scanning directories and extracting layout, format, and metadata directly from image and video file headers.

---

## 📖 Documentation

- 🚀 [**User Guide (USERGUIDE.md)**](USERGUIDE.md) — Prerequisites, build instructions, basic usage, and cross-compilation targets.
- 🛠️ [**Developer & Agent Guide (AGENTS.md)**](AGENTS.md) — Architecture diagram, codebase layout, parsing flow, and design principles.

---

## Supported Formats & Metadata

| Media Category | File Formats                                                     | Extracted Metadata                                                                                                  |
| :------------- | :--------------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------ |
| **Images**     | **JPEG**, **PNG**, **GIF**, **BMP**, **WebP**, **TIFF**          | Dimensions (Width/Height), Format, Orientation, Capture Date/Time, Camera Make/Model, GPS Latitude/Longitude (EXIF) |
| **Videos**     | **MP4** (including `.mov`, `.m4v`), **WebM**, **Matroska (MKV)** | Dimensions (Width/Height), Format, Duration (seconds), Orientation/Rotation, Creation Date/Time                     |
