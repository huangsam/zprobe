# Multi-stage build for zprobe-server
# Stage 1: Build the statically linked binary using Zig 0.16.0
FROM debian:bookworm-slim AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.16.0
WORKDIR /opt
RUN curl -L https://ziglang.org/download/0.16.0/zig-linux-x86_64-0.16.0.tar.xz | tar -xJ \
    && ln -s /opt/zig-linux-x86_64-0.16.0/zig /usr/local/bin/zig

# Set up project workspace
WORKDIR /src
COPY . .

# Build statically linked release binary targeting musl
# This ensures zero runtime dependencies on dynamic libc
RUN zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe

# Stage 2: Create a minimal, secure runtime container
FROM alpine:latest

# Install full, unrestricted ffmpeg package for thumbnail generation
RUN apk add --no-cache ffmpeg

# Create a non-root user for security
RUN addgroup -S nonroot && adduser -S nonroot -G nonroot

# Set up directory structure
WORKDIR /app
RUN mkdir -p /app/data && chown -R nonroot:nonroot /app

# Copy the statically compiled zprobe and zprobe-server binaries from the builder
COPY --from=builder /src/zig-out/bin/zprobe /usr/local/bin/zprobe
COPY --from=builder /src/zig-out/bin/zprobe-server /usr/local/bin/zprobe-server

# Use non-root user
USER nonroot

# Expose default dashboard port
EXPOSE 8085

# Define entrypoint to run the server
# Mount the database at /app/data/zprobe_cache.db or pass a custom path
ENTRYPOINT ["zprobe-server", "--port", "8085", "--db", "/app/data/zprobe_cache.db"]
