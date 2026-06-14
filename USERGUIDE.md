# zprobe User Guide

This guide provides instructions on how to install, build, run, and cross-compile `zprobe` for different platforms.

---

## Getting Started

### Prerequisites

Ensure you have **Zig 0.16.0** installed on your system.

### Build and Run

You can run the test suite, build the executable, and scan media directories using the following commands:

```bash
# Run the test suite
zig build test

# Build the executable in ReleaseSafe mode
zig build -OReleaseSafe

# Run zprobe on a directory
./zig-out/bin/zprobe /path/to/media/directory

# Run in JSON mode
./zig-out/bin/zprobe --json /path/to/media/directory
```

---

## Cross-Compilation

One of Zig's powerful features is its out-of-the-box cross-compilation capability. You can compile `zprobe` for other platforms and architectures without installing external toolchains.

Here are common cross-compilation targets:

```bash
# Synology NAS / Raspberry Pi (ARM64 Linux, statically linked, size-optimized)
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall

# Standard Intel/AMD Linux (64-bit, statically linked with musl)
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast

# Windows (64-bit portable executable)
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe

# Apple Silicon macOS (native ARM64 binary)
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast
```
