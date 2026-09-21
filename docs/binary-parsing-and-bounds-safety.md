# Engineering Learnings: Binary Parsing & Bounds Safety

## Context & The Threat Model

Media files present a hazardous attack surface in systems programming:

1. **Externally supplied and untrusted**: Sourced from arbitrary, unverified inputs.
2. **Variable-length and nested**: Structured as hierarchical Tag-Length-Value (TLV) containers.
3. **Historical attack vectors**: Prone to buffer over-reads, integer overflow on pointer offsets, and recursive stack exhaustion.

In `zprobe`, parsers run at maximum throughput across thousands of media files without crashing, leaking memory, or exposing vulnerabilities. This document details how `src/core/byte_reader.zig` and format parsers in `src/formats/` enforce safety at the bit and byte level.

---

## The Core Abstraction: `ByteReader`

Rather than raw pointer arithmetic or manual slice indexing, all stream-based binary decoding flows through `ByteReader` (`src/core/byte_reader.zig`):

```zig
pub const ByteReader = struct {
    buffer: []const u8,
    offset: usize = 0,
    endian: std.builtin.Endian,
    ...
};
```

### 1. Safe Arithmetic: Preventing Integer Overflow via Subtraction Checks

A common vulnerability in binary parsers is integer wrap-around when checking offsets:

```c
// VULNERABLE (C/C++):
if (offset + count > buffer_len) return ERROR; // offset + count can overflow!
```

`ByteReader` eliminates integer overflow by strictly checking requested counts against the remaining capacity via subtraction:

```zig
pub fn remaining(self: ByteReader) usize {
    return self.buffer.len - self.offset;
}

pub fn skip(self: *ByteReader, count: usize) !void {
    if (count > self.remaining()) return error.OutOfBounds;
    self.offset += count;
}
```

Because `count > self.remaining()` is evaluated before mutating `self.offset`, wrap-around is mathematically impossible.

---

### 2. Nested Sub-Readers: Isolating Scope in Hierarchical Formats

Media formats are organized hierarchically: container boxes nest deeper sub-boxes.

A parser that operates on global offsets can easily lose track of container boundaries and read into adjacent chunks. `ByteReader` solves this with `.subReader(size)`:

```zig
pub fn subReader(self: *ByteReader, size: usize) !ByteReader {
    if (size > self.remaining()) return error.OutOfBounds;
    const sub_buf = self.buffer[self.offset .. self.offset + size];
    self.offset += size;
    return ByteReader.init(sub_buf, self.endian);
}
```

**Benefits**:

- **Scope isolation**: The sub-reader's `buffer.len` is strictly restricted to `size`. It is physically impossible for downstream parser logic to read past the container boundary.
- **Relative offset arithmetic**: Child parsers read from offset `0` within their own chunk without needing to know their parent's absolute file position.

---

## Format-Specific Hardening Patterns

### 1. Recursion Limits: Defeating Circular Reference DoS

Complex formats like TIFF and MP4 allow chains and containers to reference other offsets. Adversarial or corrupted files can introduce circular loops that exhaust call stack memory.

#### TIFF IFD Traversal (`src/formats/images/tiff.zig`)

TIFF files can link multiple Image File Directories (IFDs) and sub-IFDs.

```zig
pub fn parseIfd(
    allocator: std.mem.Allocator,
    root_reader: *ByteReader,
    ifd_offset: usize,
    meta: *ImageMetadata,
    depth: usize,
) !void {
    if (depth > 4) return; // Hard limit prevents circular IFD recursion
    ...
}
```

#### MP4 Box Traversal (`src/formats/videos/mp4.zig`)

ISO Base Media File Format (ISOBMFF) boxes nest arbitrarily.

```zig
pub fn findTkhdInReader(reader: *ByteReader, depth: usize) ?Dims {
    if (depth > 16) return null; // Hard limit prevents deep nesting stack exhaustion
    ...
}
```

---

### 2. Variable-Size Integer (VINT) Validation (WebM / EBML)

Matroska and WebM use EBML Variable-Size Integers (VINTs) where the number of leading zero bits determines the integer width (`src/formats/videos/ebml.zig`).

```zig
pub fn getVintSize(first_byte: u8) !usize {
    if (first_byte == 0) return error.InvalidVint;
    return @clz(first_byte) + 1; // Count leading zeros using CPU intrinsic
}
```

To prevent unhandled states, EBML parsers explicitly check for undefined/unknown size markers (all data bits set to `1`) using `isVintUnknown()` before allocating or seeking into elements.

---

### 3. Bit-Packed Dimension Extraction (WebP VP8 / VP8L)

In WebP files (`src/formats/images/webp.zig`):

- **VP8 (Lossy)**: The first 3 bytes after the sync code (`0x9d 0x01 0x2a`) store 14-bit width and 14-bit height.
- **VP8L (Lossless)**: A 32-bit bitfield encodes width (14 bits), height (14 bits), alpha flag (1 bit), and version (3 bits).

```zig
const val = @as(u32, header[21]) |
    (@as(u32, header[22]) << 8) |
    (@as(u32, header[23]) << 16) |
    (@as(u32, header[24]) << 24);
const w = (val & 0x3fff) + 1;
const h = ((val >> 14) & 0x3fff) + 1;
```

Boundary checking (`if (header.len < 25) return error.WebpTooShort;`) occurs prior to any bit shifting, preventing out-of-bounds reads.

---

### 4. JPEG Marker Stream Scanning & Byte Stuffing

In standard JPEG streams (`src/formats/images/jpeg.zig`), markers begin with `0xff`. However:

- `0xff 0x00`: Escaped byte inside compressed entropy data (byte stuffing).
- `0xff 0xff`: Stuffed fill byte.
- `0xd8`: Start of Image (SOI) - no length field.
- `0xd0`–`0xd7`: Restart markers (RSTn) - no length field.

The parser tracks state dynamically:

```zig
if (marker == 0xff) {
    off += 1;
    continue;
}
if (marker >= 0xd0 and marker <= 0xd7) {
    off += 2; // Restart marker: skip pair only
} else {
    const seg_len = @as(u16, header[off + 2]) << 8 | @as(u16, header[off + 3]);
    off += 2 + seg_len;
}
```

At every step, `if (off > header.len) break;` guarantees the parser terminates immediately if segment lengths exceed the buffer.

---

## Summary of Defensive Rules

1. **Never use unbounded pointer arithmetic**: Rely on `ByteReader` or slices with known bounds.
2. **Bounds checks must use subtraction**: Check `count > remaining()` rather than `offset + count > len`.
3. **Enforce hard recursion limits**: Cap recursive container traversals (TIFF IFDs $\le 4$, MP4 boxes $\le 16$).
4. **Isolate TLV scopes**: When entering a container element, spawn a `.subReader(size)` to prevent reads from spilling into neighboring blocks.
5. **Fail fast on corruption**: Return specific Zig error set members (`error.OutOfBounds`, `error.PngTooShort`, `error.InvalidVint`) to allow calling workers to skip malformed files cleanly.
