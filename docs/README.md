# Architecture & Engineering Documentation (`docs/`)

This directory contains technical deep-dives, architectural decision records (ADRs), and engineering learnings for the `zprobe` engine.

While [`AGENTS.md`](../AGENTS.md) provides high-level development rules and repository orientation, these documents explain the foundational design patterns, trade-offs, and failure-mode defenses implemented throughout the codebase.

---

## Document Index

1. **[`language-selection-and-tradeoffs.md`](./language-selection-and-tradeoffs.md)**
    * Evaluation of **Zig vs. Rust vs. Go vs. C++** for high-throughput media parsing.
    * Compares memory allocation models, untrusted binary safety, zero-copy sub-readers, and SQLite C-FFI performance.

2. **[`binary-parsing-and-bounds-safety.md`](./binary-parsing-and-bounds-safety.md)**
    * Architecture of `ByteReader` for hierarchical Tag-Length-Value (TLV) stream decoding.
    * Integer overflow defense using subtraction checks, nested sub-readers for container isolation, and hard recursion limits to prevent circular DoS attacks.

3. **[`memory-management-and-arenas.md`](./memory-management-and-arenas.md)**
    * Eliminating global heap lock contention across multi-threaded worker pools.
    * Per-task `ArenaAllocator` lifecycles, zero-GC $O(1)$ batch memory deallocation, and leak-free error handling.

4. **[`sqlite-wal-and-concurrency.md`](./sqlite-wal-and-concurrency.md)**
    * Managing high-throughput multi-threaded writes and simultaneous HTTP dashboard reads.
    * Write-Ahead Logging (WAL) configuration, 5-second busy timeouts, application-level shared `RwLock` wrappers, and transactional stale-path pruning.

5. **[`content-keyed-artifacts-and-caching.md`](./content-keyed-artifacts-and-caching.md)**
    * Sub-millisecond content deduplication using chunked SHA-256 signatures (`computeFastHash`).
    * Two-level hex-sharded on-disk storage (`<aa>/<bb>/<hash>.jpg`) and "never claim without a stat" filesystem verification.
