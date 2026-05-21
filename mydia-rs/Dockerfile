# syntax=docker/dockerfile:1.4
#
# mydia-rs production image.
#
# The Rust binary links both sqlx drivers: SQLite is statically compiled
# in via libsqlite3-sys's `bundled` feature (no system libsqlite needed
# at runtime), and Postgres uses sqlx's pure-Rust driver (no libpq
# needed). The operator selects the engine at runtime via `database.type`
# in mydia.toml (or `MYDIA_DATABASE__TYPE`). One image, both engines —
# no separate `:latest-pg` variant; that split only made sense for the
# Phoenix image because Ecto's adapter is compiled into the BEAM release.

ARG RUST_VERSION=1.86
ARG ALPINE_VERSION=3.20

# ============================================
# Build stage
# ============================================
FROM rust:${RUST_VERSION}-alpine AS builder

RUN apk add --no-cache \
    build-base \
    musl-dev \
    pkgconfig \
    openssl-dev \
    openssl-libs-static

WORKDIR /build

# Copy workspace manifests first so Cargo can resolve the dependency
# graph before the bulk source comes in. This lets the BuildKit cache
# layer cache the bulk of the dependency compile when only source
# files change.
COPY mydia-rs/Cargo.toml mydia-rs/Cargo.lock mydia-rs/rust-toolchain.toml ./
COPY mydia-rs/crates ./crates
COPY mydia-rs/bin ./bin
# Reference path-dep for the p2p core lives outside mydia-rs/ so the
# directory layout in the image mirrors the repo's directory layout.
# Copy it in once we wire crates/p2p (U29).

# Build the release binary.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release --bin mydia-rs --bin mydia-rs-cli \
    && cp target/release/mydia-rs /tmp/mydia-rs \
    && cp target/release/mydia-rs-cli /tmp/mydia-rs-cli

# ============================================
# Runtime stage
# ============================================
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache \
    ca-certificates \
    ffmpeg \
    tini

WORKDIR /app

COPY --from=builder /tmp/mydia-rs /usr/local/bin/mydia-rs
COPY --from=builder /tmp/mydia-rs-cli /usr/local/bin/mydia-rs-cli
COPY mydia-rs/config.example.toml /app/config.example.toml

# Default config path. Operators override with `--config /etc/mydia/mydia.toml`
# or the MYDIA_CONFIG env var; the example file is here as a reference.
ENV MYDIA_CONFIG=/etc/mydia/mydia.toml

# Non-root user. mydia-rs writes to:
#   - SQLite DB file (if configured)
#   - HLS temp dir (default /tmp/mydia-hls)
#   - Library directories (read-only mount in production)
# Operators bind-mount /etc/mydia and any data dir as needed.
RUN addgroup -S mydia && adduser -S -G mydia mydia \
    && mkdir -p /etc/mydia /var/lib/mydia /tmp/mydia-hls \
    && chown -R mydia:mydia /etc/mydia /var/lib/mydia /tmp/mydia-hls

USER mydia

EXPOSE 4001

# tini reaps zombies left behind by short-lived ffprobe / ffmpeg
# subprocesses the library scanner and HLS pipeline spawn.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/mydia-rs"]
