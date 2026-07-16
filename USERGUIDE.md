# zprobe User Guide

This guide provides instructions on how to install, build, run, and cross-compile `zprobe` for different platforms.

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

# Run zprobe on one or more directories
./zig-out/bin/zprobe /path/to/media/directory1 /path/to/media/directory2

# Run in JSON mode with a SQLite caching database
./zig-out/bin/zprobe --json --db /path/to/cache.db /path/to/media/directory

# Run with custom concurrency (e.g. 2 threads) and bypass thumbnail generation (saves CPU/disk writes on NAS)
./zig-out/bin/zprobe -j 2 --no-thumbnails --db /path/to/cache.db /path/to/media/directory

# Run daily scan and automatically prune stale cache entries for files deleted/moved in the target directories
./zig-out/bin/zprobe --db /path/to/cache.db --prune /path/to/media/directory
```

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

## Dashboard Web Server

`zprobe` includes a self-contained web server (`zprobe-server`) that reads the SQLite cache database and displays a visual metadata dashboard (including metrics cards, interactive stats charts, and a catalog browser).

### Running the Server

Launch the server by specifying a port and your cache database:

```bash
./zig-out/bin/zprobe-server --port 8080 --db /path/to/cache.db
```

Open `http://localhost:8080` in your web browser to access the dashboard.

### Basic Authentication (Optional)

To secure the server for remote access or deployment, you can configure HTTP Basic Authentication by setting the `ZPROBE_AUTH_USER` and `ZPROBE_AUTH_PASS` environment variables before starting `zprobe-server`:

```bash
# Run with basic authentication
ZPROBE_AUTH_USER=admin ZPROBE_AUTH_PASS=secretpassword ./zig-out/bin/zprobe-server --port 8080 --db /path/to/cache.db
```

If these environment variables are not set, the server runs in "authless" mode, allowing access without credentials.

### Concurrent Live Scans (WAL Mode)

The server and cache database are configured with SQLite's **Write-Ahead Logging (WAL)** mode. This allows you to run live directory scans via the CLI while the server is active without locking the database:

```bash
# In a separate terminal while the server is running:
./zig-out/bin/zprobe --db /path/to/cache.db /path/to/new/photos
```

### Running as a Service (systemd)

`zprobe-server` can generate its own systemd service file tailored specifically to the target environment:

1. Copy the compiled `zprobe-server` binary to its deployment location (e.g. `/usr/local/bin/zprobe-server`).
2. Run the server with your desired configuration flags and `--setup-service` to output the service configuration:
   ```bash
   /usr/local/bin/zprobe-server --port 8085 --db /var/lib/zprobe/zprobe_cache.db --setup-service > zprobe-server.service
   ```
   This dynamically detects the current user, working directory, absolute path of the executable, and parameters to output a valid systemd configuration.
3. Move the file to your systemd services directory and enable it:
   ```bash
   sudo mv zprobe-server.service /etc/systemd/system/zprobe-server.service
   sudo systemctl daemon-reload
   sudo systemctl enable zprobe-server.service
   sudo systemctl start zprobe-server.service
   ```

### Running via Docker

Alternatively, you can run `zprobe-server` inside a lightweight container:

1. Build the Docker image from the root of the workspace.

   For a single platform (e.g. host-native):

   ```bash
   docker build -t zprobe-server .
   ```

   For multiple architectures concurrently (e.g. to run on both standard Intel/AMD `x86_64` servers and ARM64 platforms like Synology NAS or Raspberry Pi) without Rosetta/QEMU emulation overhead:

   ```bash
   docker buildx build --platform linux/amd64,linux/arm64 -t zprobe-server:latest .
   ```

2. Start the container, mounting the directory hosting your cache database (optionally passing basic auth environment variables):
   ```bash
   docker run -d \
     -p 8085:8085 \
     -e ZPROBE_AUTH_USER=admin \
     -e ZPROBE_AUTH_PASS=secretpassword \
     -v /volume1/homes/sunbunbun/Tools:/app/data \
     --name zprobe-server \
     zprobe-server
   ```

### REST API Reference

The server exposes the following JSON endpoints:

- **`GET /api/stats`**: Returns database summary metrics including total file counts/sizes, format distributions, camera models, and video duration tiers.
- **`GET /api/media`**: Returns paginated, sorted, and filtered lists of media files.
  - **Query Parameters:**
    - `limit`: Number of records to return (default: 25).
    - `offset`: Record index offset (default: 0).
    - `sort`: Column to sort by (`path`, `size`, `format`, `width`, `height`, `duration_sec`, `camera_model`, `create_time`).
    - `order`: Sort order (`asc` or `desc`).
    - `search`: Substring filter matching file paths or camera model.
    - `format`: Match exact format (e.g. `jpeg`, `mp4`).
    - `type`: Match file category (`image` or `video`).
    - `date_from`: Filter files captured on or after this ISO date (`YYYY-MM-DD`).
    - `date_to`: Filter files captured on or before this ISO date (`YYYY-MM-DD`).
    - `size_min`: Filter files larger than or equal to this size in bytes.
    - `size_max`: Filter files smaller than or equal to this size in bytes.
