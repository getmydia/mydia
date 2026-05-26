# syntax=docker/dockerfile:1.4
#
# Development image for the mydia-rs Rust workspace.
#
# Bakes in Rust, sqlx-cli, ffmpeg, and Tailwind v4. The default CMD
# runs `cargo run --bin mydia-rs` (axum on :4002). The Vite dev server
# runs in a separate `rs-frontend` container — see compose.yml.

# Dev image: 1.88 (newer than production's 1.86) supports latest crate deps.
ARG RUST_VERSION=1.88
FROM rust:${RUST_VERSION}-bookworm

# System deps: build toolchain for sqlx/openssl/postgres-sys, ffmpeg for
# the streaming crate, gosu for the LOCAL_UID re-exec trick, curl for
# downloads.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential \
      pkg-config \
      libssl-dev \
      libpq-dev \
      libsqlite3-dev \
      ca-certificates \
      curl \
      git \
      gosu \
      ffmpeg \
      postgresql-client && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Components match rust-toolchain.toml in mydia-rs/.
RUN rustup component add rustfmt clippy && \
    chmod -R a+rx /usr/local/cargo /usr/local/rustup

# sqlx-cli for offline-cache refresh (`./dev rs sqlx-prepare`).
RUN cargo install --locked --version 0.8.6 sqlx-cli \
      --no-default-features --features rustls,postgres,sqlite

# cargo-watch for auto-reload during development.
RUN cargo install --locked cargo-watch

# Tailwind v4 standalone — same pin as mydia-rs/Dockerfile.
ARG TAILWIND_VERSION=4.1.18
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) tw_arch="linux-x64" ;; \
        arm64) tw_arch="linux-arm64" ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/tailwindcss \
        "https://github.com/tailwindlabs/tailwindcss/releases/download/v${TAILWIND_VERSION}/tailwindcss-${tw_arch}"; \
    chmod +x /usr/local/bin/tailwindcss

WORKDIR /app/mydia-rs

EXPOSE 4002

COPY docker-entrypoint-rs.sh /usr/local/bin/docker-entrypoint-rs.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-rs.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint-rs.sh"]
CMD ["cargo", "watch", "-x", "run --bin mydia-rs", "--clear"]
