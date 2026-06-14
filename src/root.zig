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

pub const media_scan = @import("crawler/media_scan.zig");
pub const image_meta = struct {
    pub const ImageMetadata = @import("formats/images/common.zig").ImageMetadata;
    pub const parseFile = @import("formats/images/common.zig").parseFile;
};
pub const video_meta = struct {
    pub const VideoInfo = @import("formats/videos/common.zig").VideoInfo;
    pub const getVideoMetadata = @import("formats/videos/common.zig").getVideoMetadata;
};
pub const byte_reader = @import("core/byte_reader.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("core/byte_reader.zig");
    _ = @import("core/utils.zig");
    _ = @import("crawler/media_scan.zig");
    _ = @import("formats/images/common.zig");
    _ = @import("formats/images/jpeg.zig");
    _ = @import("formats/images/png.zig");
    _ = @import("formats/images/gif.zig");
    _ = @import("formats/images/bmp.zig");
    _ = @import("formats/images/webp.zig");
    _ = @import("formats/images/tiff.zig");
    _ = @import("formats/videos/common.zig");
    _ = @import("formats/videos/mp4.zig");
    _ = @import("formats/videos/ebml.zig");
}
