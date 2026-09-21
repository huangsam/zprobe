//! # zprobe: Media Scanner and Metadata Parser
//!
//! This library provides tools to recursively scan directories for media files
//! (images and videos) and parse their headers to extract metadata (dimensions, format, size)
//! without external dependencies.
//!
//! ## Modules
//! - `media_scan.zig`: Core recursion logic and file type extension filtering.
//! - `image_meta.zig`: In-memory and streaming parsers for PNG, GIF, BMP, and JPEG formats.
//! - `video_meta.zig`: Recursive MP4 box parser for track display dimensions.

const std = @import("std");

/// Directory crawling and media file filtering interface.
pub const media_scan = @import("crawler/media_scan.zig");

/// Image metadata parsing and information extraction interface.
pub const image_meta = struct {
    /// Re-export of the main image metadata struct.
    pub const ImageMetadata = @import("formats/images/common.zig").ImageMetadata;
    /// Re-export of the file parser function.
    pub const parseFile = @import("formats/images/common.zig").parseFile;
};

/// Video metadata parsing and information extraction interface.
pub const video_meta = struct {
    /// Re-export of the main video metadata struct.
    pub const VideoInfo = @import("formats/videos/common.zig").VideoInfo;
    /// Re-export of the video parser function.
    pub const getVideoMetadata = @import("formats/videos/common.zig").getVideoMetadata;
};

/// Endian-aware stream reading interface.
pub const byte_reader = @import("core/byte_reader.zig");

/// Database caching and cataloging interface.
pub const db = @import("core/db.zig");

/// Fast content hashing interface.
pub const hashing = @import("core/hashing.zig");

/// Utility functions.
pub const utils = @import("core/utils.zig");

/// Command-line interface parsing module.
pub const cli = @import("cli.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("main.zig");
    _ = @import("core/db.zig");
    _ = @import("core/hashing.zig");
    _ = @import("core/byte_reader.zig");
    _ = @import("core/utils.zig");
    _ = @import("crawler/media_scan.zig");
    _ = @import("cli/options.zig");
    _ = @import("cli/ffmpeg.zig");
    _ = @import("cli/format_handler.zig");
    _ = @import("cli/output_formatter.zig");
    _ = @import("cli/worker_pool.zig");
    _ = @import("formats/images/common.zig");
    _ = @import("formats/images/jpeg.zig");
    _ = @import("formats/images/png.zig");
    _ = @import("formats/images/gif.zig");
    _ = @import("formats/images/bmp.zig");
    _ = @import("formats/images/webp.zig");
    _ = @import("formats/images/tiff.zig");
    _ = @import("formats/images/avif.zig");
    _ = @import("formats/images/ico.zig");
    _ = @import("formats/images/jxl.zig");
    _ = @import("formats/videos/common.zig");
    _ = @import("formats/videos/mp4.zig");
    _ = @import("formats/videos/ebml.zig");
}
