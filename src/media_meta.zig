//! Shared types for media metadata.

/// Known image and video formats we can parse.
pub const MediaType = enum {
    jpeg,
    png,
    gif,
    bmp,
    tiff,
    webp,
    mp4,
    webm,
};

/// Image-specific metadata extracted from headers.
pub const ImageMeta = struct {
    format: MediaType,
    width: u32,
    height: u32,
};

/// Video-specific metadata extracted from container atoms.
pub const VideoMeta = struct {
    format: MediaType,
    width: u32,
    height: u32,
    duration_ms: ?u64 = null,
    fps: ?f64 = null,
};

/// Unified result carrying the file path and its parsed metadata (if any).
pub const MediaResult = struct {
    path: []const u8,
    size: u64,
    image_meta: ?ImageMeta = null,
    video_meta: ?VideoMeta = null,
};
