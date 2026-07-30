# syntax=docker/dockerfile:1.4

# ============================================
# Flutter Build Stage
# ============================================
# The Flutter version comes from player/.fvmrc, the single source of truth shared
# with devenv.nix, player/flake.nix and the CI workflows. Nothing to sync here.
#
# This installs the SDK rather than using a cirruslabs/flutter image because
# cirruslabs lags patch releases, so no tag of theirs can be relied on to match
# .fvmrc. Installing also skips the Android SDK and JDK that image bundles and
# this web build never touches.
#
# Do not reintroduce a version number in this comment. The repo asserts that
# .fvmrc is the only file naming a Flutter version, and the check is a plain grep.
FROM debian:bookworm-slim AS flutter-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      jq \
      unzip \
      xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Layer keyed on .fvmrc alone, so the SDK is re-downloaded only when the pin
# moves. safe.directory is required because the SDK tarball ships a git checkout
# that Flutter shells out to, owned by root here. precache --web warms the web
# artifacts inside this cached layer so `flutter build web` does not fetch them
# on every build.
COPY player/.fvmrc /tmp/.fvmrc
RUN FLUTTER_VERSION="$(jq -r .flutter /tmp/.fvmrc)" && \
    curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
      | tar -xJ -C /opt && \
    git config --global --add safe.directory /opt/flutter && \
    /opt/flutter/bin/flutter config --no-analytics && \
    /opt/flutter/bin/flutter precache --web

ENV PATH="/opt/flutter/bin:${PATH}"

WORKDIR /app/player

# Copy player source
COPY player/pubspec.yaml player/pubspec.lock ./
COPY player/build.yaml ./
COPY player/lib ./lib
COPY player/web ./web
COPY player/rust_builder ./rust_builder

# Copy the GraphQL schema (resolves symlink from priv/graphql/)
COPY priv/graphql/schema.graphql ./lib/graphql/schema.graphql

# Install dependencies, generate code, and build
# Cache pub packages to avoid re-downloading 1656 dependencies each build
RUN --mount=type=cache,target=/root/.pub-cache,sharing=locked \
    flutter pub get && \
    dart run build_runner build && \
    flutter build web --release --base-href /player/ --tree-shake-icons

# ============================================
# Elixir Build Stage
# ============================================
FROM elixir:1.19-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm \
    sqlite-dev \
    postgresql16-dev \
    curl \
    ca-certificates

# Rust via rustup (not apk) so the wasm32 target is available for the bundled
# plugin guests built by the :plugins mix compiler — apk's rust cannot
# `rustup target add`. The same host toolchain still builds the p2p NIF.
# Keep the default CARGO_HOME (/root/.cargo) so the existing registry/git cache
# mounts on the compile steps below still apply.
#
# PINNED to 1.96 to match devenv.nix (languages.rust) and CI. The guest
# is a wasip2 component whose WASI world tracks the Rust version (1.96 -> wasi
# 0.2.6); the runtime host is wasmex 0.14 / wasmtime 39, which only validates up
# to wasi 0.2.6. A bleeding-edge `stable` emits wasi 0.2.9 and the bundled plugin
# would fail to instantiate at runtime. Bump together with the nix toolchain.
ENV PATH="/root/.cargo/bin:${PATH}"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain 1.96.0 --profile minimal --no-modify-path && \
    rustup target add wasm32-wasip2

# Increase hex timeout for slow networks/CI
ENV HEX_HTTP_TIMEOUT=300000

# Install Hex and Rebar
RUN mix local.hex --force && mix local.rebar --force

# Database type: sqlite (default) or postgres
# This is a BUILD-TIME argument that determines which database adapter is compiled into the release
# It CANNOT be changed at runtime - each Docker image is built for a specific database
ARG DATABASE_TYPE=sqlite

# Build commit hash for development/master builds
# When set, the version will display as "X.Y.Z*<short-commit>" instead of just "X.Y.Z"
ARG BUILD_COMMIT=""

# Set build environment
ENV MIX_ENV=prod
ENV DATABASE_TYPE=${DATABASE_TYPE}
ENV BUILD_COMMIT=${BUILD_COMMIT}

# Create app directory
WORKDIR /app

# Copy dependency manifests
COPY mix.exs mix.lock ./

# Install dependencies
# Cache hex packages to avoid re-downloading each build
RUN --mount=type=cache,target=/root/.hex,sharing=locked \
    mix deps.get --only prod

# Apply patches to dependencies
# Fix ueberauth_oidcc to respect user-provided response_mode option
# This prevents auto-selection of JARM modes (query.jwt) which some OIDC providers
# advertise but don't properly support
COPY patches/ueberauth_oidcc_request.ex ./deps/ueberauth_oidcc/lib/ueberauth_oidcc/request.ex

# Compile dependencies
# Cache cargo registry for Rust NIF compilation (mydia_p2p_core)
RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,target=/root/.cargo/git,sharing=locked \
    --mount=type=cache,target=/app/native/mydia_p2p_core/target,sharing=locked \
    mix deps.compile

# Copy application source
COPY config ./config
COPY priv ./priv
COPY lib ./lib
COPY assets ./assets
COPY native ./native
# Bundled plugin guest sources — the :plugins compiler builds them to
# priv/plugins/*.wasm during `mix compile` below (the .wasm is gitignored).
COPY plugins ./plugins

# Copy Flutter build output from flutter-builder stage
COPY --from=flutter-builder /app/player/build/web ./priv/static/player

# Application version: set by CI from the git tag, defaults to "dev" for local builds
ARG BUILD_VERSION=""
ENV BUILD_VERSION=${BUILD_VERSION}

# Compile application (includes building Rust NIFs via Rustler)
# Cache cargo for Rust NIF compilation
RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,target=/root/.cargo/git,sharing=locked \
    --mount=type=cache,target=/app/native/mydia_p2p_core/target,sharing=locked \
    mix compile

# Fail the build if a bundled plugin's wasm artifact was not produced (the
# :plugins compiler graceful-skips a missing toolchain, so this is the guard
# that a release image never ships without its bundled plugins).
RUN for m in priv/plugins/*.json; do \
      [ -e "$m" ] || continue; \
      w="priv/plugins/$(basename "$m" .json).wasm"; \
      test -f "$w" || { echo "ERROR: missing built plugin artifact $w" >&2; exit 1; }; \
    done

# Build Phoenix assets
# Cache npm packages to avoid re-downloading each build
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    cd assets && \
    npm ci --prefix . --progress=false --no-audit --loglevel=error && \
    cd .. && \
    mix assets.deploy

# Build release
RUN mix release

# ============================================
# Runtime Stage
# ============================================
FROM erlang:28-alpine

# Database type: sqlite (default) or postgres
# This argument is only used for image labels - the actual adapter is already compiled
ARG DATABASE_TYPE=sqlite

# Add OCI labels following LinuxServer.io standards
LABEL org.opencontainers.image.title="Mydia" \
      org.opencontainers.image.description="Modern, self-hosted media management platform" \
      org.opencontainers.image.url="https://github.com/getmydia/mydia" \
      org.opencontainers.image.source="https://github.com/getmydia/mydia" \
      org.opencontainers.image.vendor="Mydia" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.database="${DATABASE_TYPE}" \
      maintainer="Mydia"

# Install runtime dependencies including LSIO-compatible tools
# libpq is needed for PostgreSQL connections at runtime
# sqlite provides the sqlite3 CLI for database inspection
# openssl is needed for self-signed certificate generation
RUN apk add --no-cache \
    sqlite \
    libpq \
    curl \
    ca-certificates \
    ffmpeg \
    fdk-aac \
    su-exec \
    tzdata \
    shadow \
    openssl

# Create app user with default UID/GID (will be updated by entrypoint if needed)
RUN addgroup -g 1000 mydia && \
    adduser -D -u 1000 -G mydia mydia

# Create necessary directories with proper permissions
RUN mkdir -p /app /config /data /media && \
    chown -R mydia:mydia /app /config /data /media

# Set working directory
WORKDIR /app

# Copy release from builder
COPY --from=builder --chown=mydia:mydia /app/_build/prod/rel/mydia ./

# Copy entrypoint script
COPY docker-entrypoint-prod.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Copy CLI wrapper script
COPY scripts/mydia-cli.sh /usr/local/bin/mydia-cli
RUN chmod +x /usr/local/bin/mydia-cli

# Set environment variables
# Note: DATABASE_TYPE is NOT set here - it's a build-time argument only
# The database adapter is compiled into the release and cannot be changed at runtime
ENV HOME=/app \
    MIX_ENV=prod \
    PHX_SERVER=true \
    DATABASE_PATH=/config/mydia.db \
    P2P_KEYPAIR_PATH=/config/p2p_keypair.bin \
    PORT=4000 \
    PUID=1000 \
    PGID=1000 \
    TZ=UTC

# Expose HTTP and HTTPS ports
EXPOSE 4000 4443

# Declare volumes following LSIO conventions
VOLUME ["/config", "/data", "/media"]

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:4000/health || exit 1

# Set entrypoint and default command
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/app/bin/mydia", "start"]
