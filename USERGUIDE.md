# zprobe User Guide

Lightweight, zero-dependency media scanner, metadata parser, and web dashboard.

## Getting Started

### Prerequisites

- **Zig 0.16.0**
- _(Optional)_ **FFmpeg** for video poster thumbnails and animated GIF previews

### Build & Run CLI

```bash
# Build executable
zig build -OReleaseSafe

# Basic scan
./zig-out/bin/zprobe /path/to/media

# Scan with SQLite caching and stale entry pruning
./zig-out/bin/zprobe --db /path/to/cache.db --prune /path/to/media

# Concurrency & animated video previews (requires FFmpeg)
./zig-out/bin/zprobe --db /path/to/cache.db --animations=on -j 4 /path/to/media

# Performance profiling & custom FFmpeg path
./zig-out/bin/zprobe --db /path/to/cache.db --profile --ffmpeg-path /usr/local/bin/ffmpeg /path/to/media
```

## Cross-Compilation

Compile stripped, size-optimized (`ReleaseSmall`) binaries for all supported platforms with static SQLite in one command:

```bash
zig build release-all
```

This populates `zig-out/bin/` with both CLI (`zprobe-<target>`) and server (`zprobe-server-<target>`) binaries:

- **`synology-arm64`**: Synology NAS (Realtek RTD1296), Raspberry Pi 4/5 (ARM64 Linux, musl static)
- **`synology-x86_64`**: Intel/AMD NAS and standard Linux servers (x86_64 Linux, musl static)
- **`macos-arm64`**: Apple Silicon macOS
- **`windows-x86_64`**: Windows x64 portable

_(For a custom one-off platform: `zig build -Dtarget=<triple> -Doptimize=ReleaseFast`)_

## Dashboard Web Server

`zprobe-server` provides an interactive browser dashboard backed by the SQLite cache. Because the database runs in SQLite's **WAL mode**, you can run live CLI scans while the server is active without locking.

```bash
# Start server (with optional HTTP basic auth)
ZPROBE_AUTH_USER=admin ZPROBE_AUTH_PASS=secret \
    ./zig-out/bin/zprobe-server --port 8080 --db /path/to/cache.db
```

Open `http://localhost:8080` to access the dashboard.

### Deployment

#### 1. Automated Remote Deployment (`zprobe-deploy`)

Builds release targets, syncs binaries and service units over SSH, and activates systemd remotely:

```bash
# Build deployment helper
zig build deploy

# Full install to remote host (supports custom SSH ports and basic auth)
./zig-out/bin/zprobe-deploy install \
    --host admin@nas.local:2222 \
    --remote-dir /volume1/docker/zprobe \
    --auth-user admin \
    --auth-pass secret
```

#### 2. Local systemd Service

Generate a systemd unit file directly tailored to the current machine:

```bash
# Output systemd unit configuration
/usr/local/bin/zprobe-server --port 8085 --db /var/lib/zprobe/cache.db --setup-service > zprobe-server.service

# Install and start service
sudo mv zprobe-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable zprobe-server.service
sudo systemctl start zprobe-server.service
```

#### 3. Docker Container

Run as a container mounting the database directory:

```bash
docker run -d \
    -p 8085:8085 \
    -e ZPROBE_AUTH_USER=admin \
    -e ZPROBE_AUTH_PASS=secret \
    -v /volume1/docker/zprobe:/app/data \
    --name zprobe-server \
    zprobe-server
```

## REST API Reference

The server exposes the following JSON endpoints:

- **`GET /api/stats`**: Summary metrics (total files, catalog size, format distributions, camera models, video duration tiers).
- **`GET /api/media`**: Paginated, filterable media records.
    - _Pagination_: `limit` (default 25, max 100), `offset` (default 0).
    - _Filters_: `search`, `format` (e.g. `jpeg`, `mp4`), `type` (`image`|`video`), `date_from` / `date_to` (`YYYY-MM-DD`), `size_min` / `size_max` (bytes).
    - _Sorting_: `sort` (`path`, `size`, `format`, `width`, `height`, `duration_sec`, `camera_model`, `create_time`), `order` (`asc`|`desc`).
- **`GET /api/thumbnail`**: Media preview asset (`path=<url-encoded-path>`, optional `animated=1` for video GIF preview).
