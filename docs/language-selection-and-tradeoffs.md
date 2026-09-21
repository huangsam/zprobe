# Architecture Decision & Learnings: Language Selection & Trade-offs

## Context & Purpose

`zprobe` is a high-performance media scanner and cataloging engine that:
1. Scans local filesystems concurrently for media files.
2. Decodes binary headers to extract dimensions, durations, codecs, and EXIF metadata.
3. Computes fast content signatures (`computeFastHash`) to deduplicate identical files.
4. Caches metadata in SQLite and serves an embedded HTTP dashboard.

This document records the architectural evaluation of **Zig** versus **Rust**, **Go**, and **C++** for the core parsing engine (`src/core` and `src/formats`) and explains the technical trade-offs of this choice.

---

## Architectural Requirements

The domain of binary media parsing imposes strict requirements on the language and runtime:

* **Zero-Allocation / Arena Control**: Multi-threaded scanning demands isolated memory lifecycles to avoid heap lock contention and GC latency.
* **Safe Binary Stream Traversal**: Untrusted nested TLV containers require strict slice bounds checking and overflow prevention to eliminate CVE risks.
* **Endian & Bitfield Decoding**: Media formats mix big-endian and little-endian integers alongside packed sub-byte bitfields.
* **Native C Interop**: SQLite integration requires low-overhead C FFI.
* **Single Binary Distribution**: Self-contained deployment without runtime or dynamic library dependencies.

---

## Language Comparison Matrix

| Architectural Vector | Go | C++ | Rust | Zig |
| :--- | :--- | :--- | :--- | :--- |
| **Memory Model** | Garbage Collector (GC) | RAII / Manual (`new`/`delete`) | Ownership & Borrow Checker | Explicit Allocators (`std.mem.Allocator`) |
| **Worker Arena Isolation** | ❌ Hard (heap escape) | ⚠️ Clunky (`std::pmr`) | ⚠️ Unstable (`allocator_api`) | ✅ First-Class (`std.heap.ArenaAllocator`) |
| **Slice Bounds Safety** | ✅ Safe (runtime panic) | ❌ Manual (UB / over-read risks) | ✅ Safe (runtime panic) | ✅ Safe (`Debug`/`ReleaseSafe` bounds checks) |
| **Zero-Copy Sub-Readers** | ✅ Slices | ⚠️ `std::span` | ⚠️ Lifetime annotations (`'a`, `'b`) | ✅ Direct (`ByteReader.subReader`) |
| **Endian / Comptime Unpack** | ⚠️ Runtime standard lib | ⚠️ Templates / Intrinsics | ✅ Traits (`byteorder`, `zerocopy`) | ✅ Native Comptime (`readInt(comptime T)`) |
| **SQLite C FFI Cost** | ❌ High CGO overhead (~50–100ns) | ✅ Zero overhead | ⚠️ `bindgen` + `unsafe` blocks | ✅ Zero-overhead native `@cImport` |
| **Ecosystem Stability** | ✅ Mature (1.0+) | ✅ Mature (C++20/23) | ✅ Mature (1.0+) | ❌ Rapid evolution (pre-1.0) |

---

## Deep-Dive Evaluation

### 1. Go: Why it was the weakest fit for `src/core` and `src/formats`

While Go is an excellent language for networking, CLI utilities, and HTTP servers, it introduces friction in high-throughput binary parsers:

* **Garbage Collector Latency & Thrashing**: Media header parsing generates millions of small transient byte slices, strings, and tag structures. In Go, these allocations escape to the heap, creating frequent GC cycles and unpredictable stop-the-world pauses when parallelized across 8–16 worker threads.
* **Lack of First-Class Arenas**: In `zprobe`, every media worker initializes a per-file `ArenaAllocator` (`defer arena.deinit()`). When parsing completes or fails, all transient memory is released in an instantaneous $O(1)$ operation. In Go, arena support is experimental, and normal slice slicing easily keeps parent memory pinned.
* **CGO Call Overhead**: Go’s CGO boundary incurs a stack-switch penalty of ~50–100ns per call. Because `zprobe` performs high-frequency transactional queries, cache checks, and metadata insertions with SQLite, CGO overhead noticeably degrades scanner throughput unless a slower pure-Go SQLite port is used.
* **Bitfield & Endian Manipulation**: Go lacks compile-time integer width evaluation. Parsing custom bitfields or counting leading zeros requires manual bit shifts and runtime branching rather than inline compiler intrinsics.

### 2. C++: Maximum performance, but high memory-safety risk

C++ offers raw speed, zero-overhead C interop, and RAII, but carries severe downsides for parsing untrusted media:

* **CVE & Undefined Behavior Vulnerabilities**: Binary media parsers are historically among the most vulnerable codebases to buffer overflows, integer wrap-around (`offset + size`), and out-of-bounds reads. In C++, memory safety depends entirely on developer vigilance. While modern C++ has `std::span`, integer overflow remains undefined behavior, and uninitialized reads are silent. Zig enforces runtime bounds checking and panic-on-overflow in safe build modes.
* **Clumsy Allocator Ergonomics**: While modern C++ provides `std::pmr::monotonic_buffer_resource`, polymorphic allocators are verbose, contagious in signatures, and infrequently adopted across standard libraries.
* **Build System Friction**: Compiling C++ with SQLite, multi-threading, and cross-compilation across macOS, Linux, and Windows requires CMake, Ninja, and package managers like vcpkg or Conan. In contrast, Zig ships as a complete cross-compiling toolchain out of the box.

### 3. Rust: The strongest contender, with distinct ergonomics trade-offs

Rust is the closest alternative to Zig for this problem space. It provides memory safety without a garbage collector and features a rich parser ecosystem (`nom`, `binread`, `kamadak-exif`). However, Zig offered specific advantages for `zprobe`:

* **Zero-Copy Sub-Readers vs. Borrow Checker Friction**: In `src/core/byte_reader.zig`, `ByteReader.subReader(size)` creates bounded, nested sub-readers to parse Tag-Length-Value blocks. In Rust, threading borrowed sub-slices through recursive parser functions (`parseIfd`, `findTkhdInReader`) frequently requires complex lifetime annotations (`'a`, `'b`) and battles with the borrow checker. Zig's slices (`[]const u8`) are simple `{ ptr, len }` structs—bounds-checked at runtime, but without lifetime virality.
* **Explicit Allocator Passing vs. Global Allocator Coupling**: Rust's standard library is tightly coupled to a single global allocator; passing custom allocators down function hierarchies requires the nightly-only `allocator_api` or third-party bump-allocation crates. In Zig, `allocator: std.mem.Allocator` is an explicit parameter across all allocating functions.
* **Frictionless C Interop**: Binding SQLite in Rust requires `bindgen`, build scripts, and wrapping C calls in `unsafe` blocks. In Zig, `@cImport({ @cInclude("sqlite3.h"); })` seamlessly compiles and exposes the C ABI directly.
* **Compilation Speed**: Rust’s macro expansions and heavy trait monomorphizations result in significantly longer compile times than Zig.

### 4. Why Zig was the best fit for `src/core` and `src/formats`

#### 1. Comptime Generic Binary Decoding
In `src/core/byte_reader.zig`:
```zig
pub fn readInt(self: *ByteReader, comptime T: type) !T {
    const size = @sizeOf(T);
    if (size > self.remaining()) return error.OutOfBounds;
    const bytes = self.buffer[self.offset .. self.offset + size];
    self.offset += size;
    return std.mem.readInt(T, bytes[0..size], self.endian);
}
```
Compile-time integer width resolution generates optimal machine code (e.g., direct `bswap`/`movbe` instructions) without template metaprogramming bloat or runtime reflection.

#### 2. Per-Task Arena Allocation
In `src/cli/worker_pool.zig`:
```zig
var arena = std.heap.ArenaAllocator.init(c_ctx.allocator);
defer arena.deinit();
const arena_allocator = arena.allocator();
```
Workers process files using an arena allocator. All transient allocations (ASCII strings, EXIF arrays, temporary paths) are freed in an $O(1)$ batch upon file completion or failure, guaranteeing zero heap fragmentation and eliminating allocator lock contention across threads.

#### 3. Explicit Error Unions
Zig’s error unions (`!T`) make error conditions explicit without exception unwinding overhead. If a file is malformed, functions return `error.OutOfBounds`, `error.NotPng`, or `error.InvalidJpeg` immediately via `try`, allowing the worker pool to safely skip bad files without crashing.

#### 4. Seamless SQLite Integration
SQLite is compiled directly into the binary with zero translation layers via `@cImport`. Queries execute at native speed with zero marshaling or FFI overhead.

---

## Acknowledged Trade-offs of Choosing Zig

* **Pre-1.0 Compiler Churn**: Standard library breaking changes require periodic maintenance.
* **Hand-Rolled Parsers**: Younger package ecosystem requires writing format parsers from scratch.
* **Runtime vs. Static Safety**: Memory safety relies on runtime bounds checks and arena discipline rather than static borrow proofs.

---

## Conclusion

For `zprobe`'s parsing engine, **Zig provides the optimal balance**:
* Delivers the raw execution speed and native C ABI of C++.
* Avoids the Garbage Collector latency and CGO call overhead of Go.
* Avoids the borrow-checker lifetime friction and allocator coupling of Rust on nested sub-readers.
