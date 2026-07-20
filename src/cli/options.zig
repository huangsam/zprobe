//! Command-line interface parsing module for zprobe.
//!
//! This module provides:
//! 1. ArtifactMode enum for generation policies (off/on/rebuild)
//! 2. CliOptions struct for parsed CLI configuration
//! 3. parse helper function with error recovery and help output

const std = @import("std");

/// Generation policy for a content-keyed artifact type. `--thumbnails` and
/// `--animations` share this grammar; only their defaults and on-disk roots differ.
pub const ArtifactMode = enum {
    off,
    on,
    rebuild,

    /// Whether this run should generate the artifact when it is missing.
    pub fn generates(self: ArtifactMode) bool {
        return self != .off;
    }

    /// Whether this run should heal by on-disk existence.
    pub fn healsFromDisk(self: ArtifactMode) bool {
        return self == .rebuild;
    }
};

/// Parse an `on|off|rebuild` mode value (case-insensitive). Returns null
/// on an unrecognized value so the caller can emit a precise CLI error.
pub fn parseArtifactMode(value: []const u8) ?ArtifactMode {
    // Simple case-insensitive comparison by checking each character
    if (value.len == 3 and std.ascii.eqlIgnoreCase(value, "off")) return .off;
    if (value.len == 2 and std.ascii.eqlIgnoreCase(value, "on")) return .on;
    if (value.len == 7 and std.ascii.eqlIgnoreCase(value, "rebuild")) return .rebuild;
    return null;
}

/// Long options used for "did you mean?" suggestions on an unknown flag.
const known_flags = [_][]const u8{ "--json", "--db", "--concurrency", "--thumbnails", "--prune", "--animations", "--ffmpeg-path", "--help" };

/// Levenshtein edit distance between two strings. `row` is scratch of length `b.len + 1`.
fn levenshtein(a: []const u8, b: []const u8, row: []usize) usize {
    for (0..b.len + 1) |j| row[j] = j;
    for (a, 0..) |ca, i| {
        var prev = row[0];
        row[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cur = row[j + 1];
            const cost: usize = if (ca == cb) 0 else 1;
            row[j + 1] = @min(@min(row[j] + 1, row[j + 1] + 1), prev + cost);
            prev = cur;
        }
    }
    return row[b.len];
}

/// Suggest the closest known flag for an unrecognized flag. Returns
/// null if no close match is found.
fn suggestFlag(out: anytype, arg: []const u8) !void {
    const name = if (std.mem.indexOfScalar(u8, arg, '=')) |eq| arg[0..eq] else arg;
    if (name.len == 0) return;

    var best: ?[]const u8 = null;
    var best_dist: usize = std.math.maxInt(usize);
    var row: [64]usize = undefined;
    for (known_flags) |flag| {
        if (flag.len + 1 > row.len) continue;
        const d = levenshtein(name, flag, row[0 .. flag.len + 1]);
        if (d < best_dist) {
            best_dist = d;
            best = flag;
        }
    }
    // Only suggest when the match is close enough to be plausible: at least
    // half the characters of the longer token must line up.
    const b = best orelse return;
    if (best_dist * 2 > @max(name.len, b.len)) return;
    try out.print("Did you mean '{s}'?\n", .{b});
}

/// Whether `arg` is `flag` exactly or `flag=VALUE`.
fn flagMatches(arg: []const u8, flag: []const u8) bool {
    return std.mem.eql(u8, arg, flag) or
        (arg.len > flag.len and std.mem.startsWith(u8, arg, flag) and arg[flag.len] == '=');
}

/// Read and validate the mode value for `--thumbnails` / `--animations`, accepting
/// both `--flag=VALUE` and `--flag VALUE`. Exits(1) with a precise message on a
/// missing or unrecognized value.
fn parseModeFlag(out: anytype, args: []const []const u8, arg_idx: *usize, flag: []const u8, arg: []const u8) ArtifactMode {
    var val: []const u8 = undefined;
    if (arg.len > flag.len and arg[flag.len] == '=') {
        val = arg[flag.len + 1 ..];
    } else {
        if (arg_idx.* + 1 >= args.len) {
            out.print("Error: {s} requires a value (on|off|rebuild)\n", .{flag}) catch {};
            std.process.exit(1);
        }
        arg_idx.* += 1;
        val = args[arg_idx.*];
    }
    return parseArtifactMode(val) orelse {
        out.print("Error: unrecognized value for {s}: {s}\n", .{ flag, val }) catch {};
        std.process.exit(1);
    };
}

/// Parsed CLI options structure that captures all configuration
/// from command-line arguments.
pub const CliOptions = struct {
    json_mode: bool,
    target_db: []const u8,
    show_help: bool,
    concurrency_override: ?usize,
    thumbnails: ArtifactMode,
    animations: ArtifactMode,
    prune_mode: bool,
    ffmpeg_path_override: ?[]const u8,
    target_dirs: std.ArrayList([]const u8),

    /// Parse command-line arguments into CliOptions.
    ///
    /// Returns error message string if parsing fails, or null on success.
    /// The caller is responsible for freeing `target_db` and `target_dirs.items`.
    pub fn parse(allocator: std.mem.Allocator, args: []const []const u8, out: anytype) !CliOptions {
        var result = CliOptions{
            .json_mode = false,
            .target_db = "",
            .show_help = false,
            .concurrency_override = null,
            .thumbnails = .on,
            .animations = .off,
            .prune_mode = false,
            .ffmpeg_path_override = null,
            .target_dirs = std.ArrayList([]const u8).empty,
        };

        var arg_idx: usize = 1;
        while (arg_idx < args.len) : (arg_idx += 1) {
            const arg = args[arg_idx];
            if (std.mem.eql(u8, arg, "--json")) {
                result.json_mode = true;
            } else if (flagMatches(arg, "--thumbnails")) {
                result.thumbnails = parseModeFlag(out, args, &arg_idx, "--thumbnails", arg);
            } else if (flagMatches(arg, "--animations")) {
                result.animations = parseModeFlag(out, args, &arg_idx, "--animations", arg);
            } else if (std.mem.eql(u8, arg, "--prune")) {
                result.prune_mode = true;
            } else if (std.mem.eql(u8, arg, "--ffmpeg-path")) {
                if (arg_idx + 1 < args.len) {
                    arg_idx += 1;
                    result.ffmpeg_path_override = args[arg_idx];
                } else {
                    try out.print("Error: --ffmpeg-path option requires a value\n", .{});
                    return error.InvalidArgument;
                }
            } else if (std.mem.eql(u8, arg, "--concurrency") or std.mem.eql(u8, arg, "-j")) {
                if (arg_idx + 1 < args.len) {
                    arg_idx += 1;
                    const val = args[arg_idx];
                    const parsed = std.fmt.parseInt(usize, val, 10) catch {
                        try out.print("Error: Invalid concurrency value '{s}'\n", .{val});
                        return error.InvalidArgument;
                    };
                    if (parsed == 0) {
                        try out.print("Error: Concurrency must be at least 1\n", .{});
                        return error.InvalidArgument;
                    }
                    result.concurrency_override = parsed;
                } else {
                    try out.print("Error: --concurrency/-j option requires a value\n", .{});
                    return error.InvalidArgument;
                }
            } else if (std.mem.eql(u8, arg, "--db")) {
                if (arg_idx + 1 < args.len) {
                    arg_idx += 1;
                    result.target_db = try allocator.dupe(u8, args[arg_idx]);
                } else {
                    try out.print("Error: --db option requires a database path\n", .{});
                    return error.InvalidArgument;
                }
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                result.show_help = true;
            } else if (arg.len > 1 and arg[0] == '-') {
                try out.print("Error: Unknown option '{s}'\n", .{arg});
                try suggestFlag(out, arg);
                try out.print("Run '{s} --help' for available options.\n", .{args[0]});
                return error.InvalidArgument;
            } else {
                try result.target_dirs.append(allocator, try allocator.dupe(u8, arg));
            }
        }

        return result;
    }

    /// Free all allocated fields in CliOptions.
    pub fn deinit(self: *CliOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.target_db);
        for (self.target_dirs.items) |dir| {
            allocator.free(dir);
        }
        self.target_dirs.deinit(allocator);
    }
};

/// Print help message to the given writer.
pub fn printHelp(out: anytype, exe_name: []const u8) !void {
    try out.print(
        \\zprobe - Media header scanning and metadata indexing tool
        \\
        \\Usage:
        \\  {s} [options] <directory>...
        \\
        \\Options:
        \\  -h, --help                    Show this help message and exit
        \\  --json                        Output metadata in JSON lines format
        \\  --db <database>               Path to SQLite database for metadata caching and indexing
        \\  -j, --concurrency <n>         Number of concurrent worker threads (default: CPU-based dynamic clamp 8-16)
        \\  --thumbnails=on|off|rebuild   Static JPEG thumbnails under .zprobe_thumbnails (default: on)
        \\  --animations=on|off|rebuild   Animated previews under .zprobe_animations (default: off)
        \\  --ffmpeg-path <path>          Custom path/command for FFmpeg executable (default: ZPROBE_FFMPEG_PATH env or "ffmpeg")
        \\
        \\Supported Formats:
        \\  Images: JPEG, PNG, GIF, BMP, WebP, TIFF, AVIF, ICO, JXL
        \\  Videos: MP4, M4V, MOV, WebM, MKV, AVI, WMV, FLV
        \\
    , .{exe_name});
}

test "parseArtifactMode accepts valid values" {
    try std.testing.expectEqual(ArtifactMode.off, parseArtifactMode("off").?);
    try std.testing.expectEqual(ArtifactMode.on, parseArtifactMode("on").?);
    try std.testing.expectEqual(ArtifactMode.rebuild, parseArtifactMode("rebuild").?);
    try std.testing.expectEqual(ArtifactMode.off, parseArtifactMode("OFF").?);
    try std.testing.expectEqual(ArtifactMode.on, parseArtifactMode("ON").?);
    try std.testing.expectEqual(ArtifactMode.rebuild, parseArtifactMode("REBUILD").?);
}

test "parseArtifactMode rejects invalid values" {
    try std.testing.expect(parseArtifactMode("invalid") == null);
    try std.testing.expect(parseArtifactMode("") == null);
    try std.testing.expect(parseArtifactMode("0") == null);
}

test "flagMatches exact match" {
    try std.testing.expect(flagMatches("--json", "--json"));
    try std.testing.expect(flagMatches("--db", "--db"));
}

test "flagMatches with value" {
    try std.testing.expect(flagMatches("--thumbnails=on", "--thumbnails"));
    try std.testing.expect(flagMatches("--animations=off", "--animations"));
}

test "flagMatches no match" {
    try std.testing.expect(!flagMatches("--json", "--db"));
    try std.testing.expect(!flagMatches("--thumb", "--thumbnails"));
}
