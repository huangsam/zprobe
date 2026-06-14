//! Bounded, Endian-Aware Binary Byte Reader (TLV Stream Decoder).
//!
//! This module provides the `ByteReader` structure, which simplifies the parsing of
//! nested, variable-length binary file formats (such as MP4, TIFF, JPEG, and PNG).
//!
//! ### The Problem Addressed:
//! Media formats organize data using nested Tag-Length-Value (TLV) patterns—identical
//! in concept to ASN.1 BER (Basic Encoding Rules). Parsing these manually requires
//! carrying index counters, performing offset calculations, and enforcing buffer bounds,
//! which is highly error-prone and vulnerable to buffer overflow attacks on malformed files.
//!
//! ### The Solution:
//! `ByteReader` wraps a byte buffer and maintains a safe internal cursor.
//! Key design highlights:
//! 1. **Strict Bounds Checks**: All read/skip operations perform bounds checking and yield
//!    `error.OutOfBounds` if they exceed the buffer size.
//! 2. **Isolating Nested Sub-Readers**: The `.subReader(size)` method returns a nested
//!    `ByteReader` restricted strictly to a slice of size `size`. This mimics BER constructed
//!    type parsing—it isolates the parser scope to a single block, making it impossible
//!    to read past the block's size and keeping offset arithmetic relative to the block's start.
//! 3. **Endianness Abstraction**: Easily supports big-endian and little-endian conversions.

const std = @import("std");

/// Endian-aware reader with bounded cursor tracking and chainable sub-reader capabilities.
pub const ByteReader = struct {
    buffer: []const u8,
    offset: usize = 0,
    endian: std.builtin.Endian,

    /// Initialize a new reader wrapping the provided slice with a specific endianness.
    pub fn init(buffer: []const u8, endian: std.builtin.Endian) ByteReader {
        return .{
            .buffer = buffer,
            .endian = endian,
        };
    }

    /// Return the number of bytes remaining to be read.
    pub fn remaining(self: ByteReader) usize {
        return self.buffer.len - self.offset;
    }

    /// Advance the cursor forward by `count` bytes. Returns `error.OutOfBounds` if it goes past the end.
    pub fn skip(self: *ByteReader, count: usize) !void {
        if (self.offset + count > self.buffer.len) return error.OutOfBounds;
        self.offset += count;
    }

    /// Peek at the next `count` bytes without advancing the reader's cursor.
    pub fn peek(self: ByteReader, count: usize) ![]const u8 {
        if (self.offset + count > self.buffer.len) return error.OutOfBounds;
        return self.buffer[self.offset .. self.offset + count];
    }

    /// Yield a child `ByteReader` bounded strictly to the next `size` bytes.
    /// Advances the parent's cursor by `size` bytes. Useful for parsing nested TLV structures.
    pub fn subReader(self: *ByteReader, size: usize) !ByteReader {
        if (self.offset + size > self.buffer.len) return error.OutOfBounds;
        const sub_buf = self.buffer[self.offset .. self.offset + size];
        self.offset += size;
        return ByteReader.init(sub_buf, self.endian);
    }

    /// Read a single byte and advance the cursor by 1.
    pub fn readU8(self: *ByteReader) !u8 {
        if (self.offset + 1 > self.buffer.len) return error.OutOfBounds;
        const val = self.buffer[self.offset];
        self.offset += 1;
        return val;
    }

    /// Read a 16-bit integer and advance the cursor by 2.
    pub fn readU16(self: *ByteReader) !u16 {
        if (self.offset + 2 > self.buffer.len) return error.OutOfBounds;
        const bytes = self.buffer[self.offset .. self.offset + 2];
        self.offset += 2;
        return switch (self.endian) {
            .little => std.mem.readInt(u16, bytes[0..2], .little),
            .big => std.mem.readInt(u16, bytes[0..2], .big),
        };
    }

    pub fn readU32(self: *ByteReader) !u32 {
        if (self.offset + 4 > self.buffer.len) return error.OutOfBounds;
        const bytes = self.buffer[self.offset .. self.offset + 4];
        self.offset += 4;
        return switch (self.endian) {
            .little => std.mem.readInt(u32, bytes[0..4], .little),
            .big => std.mem.readInt(u32, bytes[0..4], .big),
        };
    }

    pub fn readI32(self: *ByteReader) !i32 {
        if (self.offset + 4 > self.buffer.len) return error.OutOfBounds;
        const bytes = self.buffer[self.offset .. self.offset + 4];
        self.offset += 4;
        return switch (self.endian) {
            .little => std.mem.readInt(i32, bytes[0..4], .little),
            .big => std.mem.readInt(i32, bytes[0..4], .big),
        };
    }

    pub fn readU64(self: *ByteReader) !u64 {
        if (self.offset + 8 > self.buffer.len) return error.OutOfBounds;
        const bytes = self.buffer[self.offset .. self.offset + 8];
        self.offset += 8;
        return switch (self.endian) {
            .little => std.mem.readInt(u64, bytes[0..8], .little),
            .big => std.mem.readInt(u64, bytes[0..8], .big),
        };
    }

    pub fn readRational(self: *ByteReader) !f64 {
        const num = try self.readU32();
        const den = try self.readU32();
        if (den == 0) return 0.0;
        return @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
    }

    pub fn readAscii(self: *ByteReader, allocator: std.mem.Allocator, count: u32) ![]const u8 {
        if (self.offset + count > self.buffer.len) return error.OutOfBounds;
        const raw = self.buffer[self.offset .. self.offset + count];
        self.offset += count;

        var len = count;
        while (len > 0 and (raw[len - 1] == 0 or raw[len - 1] == ' ')) {
            len -= 1;
        }

        const result = try allocator.alloc(u8, len);
        @memcpy(result, raw[0..len]);
        return result;
    }
};

test "ByteReader primitives and endianness" {
    // 1. Little Endian buffer
    var le_buf = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    var le_reader = ByteReader.init(&le_buf, .little);
    try std.testing.expectEqual(@as(u8, 0x01), try le_reader.readU8());
    try std.testing.expectEqual(@as(u16, 0x0302), try le_reader.readU16());
    try std.testing.expectEqual(@as(u32, 0x07060504), try le_reader.readU32());
    try std.testing.expectEqual(@as(usize, 1), le_reader.remaining());

    // 2. Big Endian buffer
    var be_buf = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    var be_reader = ByteReader.init(&be_buf, .big);
    try std.testing.expectEqual(@as(u8, 0x01), try be_reader.readU8());
    try std.testing.expectEqual(@as(u16, 0x0203), try be_reader.readU16());
    try std.testing.expectEqual(@as(u32, 0x04050607), try be_reader.readU32());
}

test "ByteReader sub-readers and bounds protection" {
    var parent_buf = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    var parent = ByteReader.init(&parent_buf, .big);

    // Spawn nested sub-reader of size 4
    var child = try parent.subReader(4);
    try std.testing.expectEqual(@as(usize, 4), child.remaining());
    try std.testing.expectEqual(@as(usize, 4), parent.remaining());

    // Read elements inside child
    try std.testing.expectEqual(@as(u8, 0x01), try child.readU8());
    try std.testing.expectEqual(@as(u16, 0x0203), try child.readU16());
    try std.testing.expectEqual(@as(u8, 0x04), try child.readU8());
    try std.testing.expectEqual(@as(usize, 0), child.remaining());

    // Out of bounds on child
    try std.testing.expectError(error.OutOfBounds, child.readU8());

    // Parent is still fully functional
    try std.testing.expectEqual(@as(u32, 0x05060708), try parent.readU32());
}

test "ByteReader readAscii string trimming" {
    const allocator = std.testing.allocator;
    const buf = "Hello World  \x00\x00";
    var reader = ByteReader.init(buf, .little);
    const str = try reader.readAscii(allocator, @intCast(buf.len));
    defer allocator.free(str);
    try std.testing.expectEqualStrings("Hello World", str);
}

test "ByteReader skip, peek, signed ints, and rationals" {
    // 1. skip and peek
    var buf1 = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var reader1 = ByteReader.init(&buf1, .big);
    const peeked = try reader1.peek(2);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, peeked);
    try reader1.skip(2);
    try std.testing.expectEqual(@as(u16, 0x0304), try reader1.readU16());

    // 2. signed ints and U64
    var buf2 = [_]u8{ 0xff, 0xff, 0xff, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    var reader2 = ByteReader.init(&buf2, .big);
    try std.testing.expectEqual(@as(i32, -256), try reader2.readI32()); // 0xffffff00 is -256
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), try reader2.readU64());

    // 3. rationals
    var buf3 = [_]u8{ 0x00, 0x00, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x02 }; // 10, 2
    var reader3 = ByteReader.init(&buf3, .big);
    try std.testing.expectEqual(@as(f64, 5.0), try reader3.readRational());
}
