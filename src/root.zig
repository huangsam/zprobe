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
