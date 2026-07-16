# Multi-stage build for zprobe-server
# Stage 1: Build the statically linked binary using Zig 0.16.0
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.16.0
ARG BUILDARCH
WORKDIR /opt
RUN if [ "$BUILDARCH" = "arm64" ]; then \
        ZIG_ARCH="aarch64"; \
    else \
        ZIG_ARCH="x86_64"; \
    fi && \
    curl -L "https://ziglang.org/download/0.16.0/zig-${ZIG_ARCH}-linux-0.16.0.tar.xz" | tar -xJ && \
    ln -s "/opt/zig-${ZIG_ARCH}-linux-0.16.0/zig" /usr/local/bin/zig

# Set up project workspace
WORKDIR /src
COPY . .

# Build statically linked release binary targeting musl
# This ensures zero runtime dependencies on dynamic libc
ARG TARGETARCH
RUN if [ "$TARGETARCH" = "arm64" ]; then \
        ZIG_TARGET="aarch64-linux-musl"; \
    else \
        ZIG_TARGET="x86_64-linux-musl"; \
    fi && \
    zig build -Dtarget=${ZIG_TARGET} -Doptimize=ReleaseSafe

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
