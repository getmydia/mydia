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
# Do not reintroduce a version number in this comment. ci-nix.yml's "Check /
# Flutter Pin" job scans every build and CI file for a Flutter version literal
# and fails on any hit, so the version is always read from .fvmrc at build time.
FROM debian:bookworm-slim AS flutter-builder

# curl and unzip are Flutter's own dependencies, not ours: bin/internal/
# update_dart_sdk.sh curls the Dart SDK zip, and the tool shells out to unzip for
# the Dart SDK and the engine artifacts precache pulls.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      jq \
      unzip \
    && rm -rf /var/lib/apt/lists/*

# Layer keyed on .fvmrc alone, so the SDK is re-fetched only when the pin moves.
#
# The SDK comes from the tagged git checkout rather than the published
# flutter_linux_*.tar.xz archive because Flutter publishes those for x64 Linux
# only, while release.yml builds this image natively on arm64 runners too. A git
# checkout carries no prebuilt Dart SDK, so update_dart_sdk.sh fetches the one
# matching whichever architecture is building.
#
# safe.directory is required because that checkout is owned by root while Flutter
# shells out to git against it. precache --web warms the web artifacts inside
# this cached layer so `flutter build web` does not fetch them on every build.
COPY player/.fvmrc /tmp/.fvmrc
RUN FLUTTER_VERSION="$(jq -r .flutter /tmp/.fvmrc)" && \
    git clone --depth 1 --branch "$FLUTTER_VERSION" \
      https://github.com/flutter/flutter.git /opt/flutter && \
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
# Everything `pubspec.yaml` declares under `flutter: assets:`/`fonts:` — the
# bundled Inter faces and their license. `flutter build web` hard-fails
# ("unable to locate asset entry in pubspec.yaml") if a declared asset is
# missing from the build context, so this must track the pubspec.
COPY player/assets ./assets

# Copy the GraphQL schema (resolves symlink from priv/graphql/)
COPY priv/graphql/schema.graphql ./lib/graphql/schema.graphql

# Install dependencies, generate code, and build
# Cache pub packages to avoid re-downloading 1656 dependencies each build
# --pwa-strategy=none: a scope holds exactly one service worker registration,
# and web/sw.js needs the app's own scope to intercept media requests over p2p.
# Leaving Flutter's worker on would mean the two replacing each other on every
# load and playback cycle. Flutter's own build prints that its service worker
# is deprecated and slated for removal.
RUN --mount=type=cache,target=/root/.pub-cache,sharing=locked \
    flutter pub get && \
    dart run build_runner build && \
    flutter build web --release --base-href /player/ --tree-shake-icons --pwa-strategy=none

# ============================================
# Elixir Build Stage
# ============================================
# Digest-pinned, not tag-pinned, because the official elixir images publish no
# Alpine-qualified tag: the variants are <version>[-otp-NN]-alpine and nothing
# more, so a tag cannot express which Alpine a builder runs on. This digest
# carries Alpine 3.23.5. It matters because this stage runs the BEAM to
# compile, and musl 1.2.6 (Alpine 3.24) aborts the VM at startup on a CPU with
# a large XSAVE area. See metadata-relay/Dockerfile for the full explanation.
#
# Nothing bumps this automatically: .github/dependabot.yml has no docker
# ecosystem. It is pinned for correctness, not currency. Move it once a
# released OTP tag carries erlang/otp#11376.
FROM elixir:1.19-alpine@sha256:c504b910bbc1d5dccefb2d81e6a49a7747b931ab737c1e774a46fdf85906ef11 AS builder

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
# The version is NOT named here. rust-toolchain.toml is copied in first and
# `rustup toolchain install` (no argument) reads both the channel and the
# wasm32-wasip2 target from it, which is also where the wasi-0.2.6 / wasmex
# constraint is documented. CI fails the build if this file names a Rust
# version again.
WORKDIR /app
COPY rust-toolchain.toml ./
ENV PATH="/root/.cargo/bin:${PATH}"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain none --profile minimal --no-modify-path && \
    rustup toolchain install

# Increase hex timeout for slow networks/CI
ENV HEX_HTTP_TIMEOUT=300000

# Install Hex and Rebar
RUN mix local.hex --force && mix local.rebar --force

# Database type: sqlite (default) or postgres
# This is a BUILD-TIME argument that determines which database adapter is compiled into the release
# It CANNOT be changed at runtime - each Docker image is built for a specific database
ARG DATABASE_TYPE=sqlite

# BUILD_COMMIT is deliberately not declared here. Its value changes on every
# commit, so setting it at this height makes every RUN below uncacheable. It
# lives beside BUILD_VERSION just above `mix compile`; the full explanation is
# in the comment there, and ci.yml fails the build if it moves back up.

# Set build environment
ENV MIX_ENV=prod
ENV DATABASE_TYPE=${DATABASE_TYPE}

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

# Build identity. BUILD_VERSION is set by CI from the git tag and defaults to
# "dev" for local builds. BUILD_COMMIT is the SHA, set for master and release
# builds so the version renders as "X.Y.Z*<short-commit>".
#
# Both are read at compile time: mix.exs reads BUILD_VERSION for the project
# version, and Mydia.System captures BUILD_COMMIT into a module attribute. Both
# also change per build, so this position, below the dependency layers and above
# `mix compile`, is load-bearing in both directions.
#
# Higher is wrong. BuildKit folds a RUN's environment into its ExecOp cache key,
# while a COPY is a FileOp that ignores it, so a commit-varying ENV above
# `mix deps.get` and `mix deps.compile` leaves those two permanently uncacheable
# in ci-docker.yml, release.yml and ci-player-e2e.yml at once. That asymmetry is
# what hid the bug for so long: the build log showed `COPY mix.exs mix.lock` as
# CACHED with every RUN beneath it missing, which reads as impossible. Here it
# costs nothing, because the source COPYs above already vary per commit.
#
# Lower is also wrong. `mix release` recompiles nothing, so setting BUILD_COMMIT
# after `mix compile` leaves Mydia.System's attribute nil and drops the commit
# suffix from the version and from crash reports, with no build or test failure
# to catch it. ci.yml guards this placement.
ARG BUILD_VERSION=""
ENV BUILD_VERSION=${BUILD_VERSION}
ARG BUILD_COMMIT=""
ENV BUILD_COMMIT=${BUILD_COMMIT}

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
# Alpine 3.23, and not an erlang image. metadata-relay/Dockerfile carries the
# full explanation: musl 1.2.6, which Alpine 3.24 ships, tightened
# sigaltstack() to reject any size below sysconf(_SC_MINSIGSTKSZ), which on a
# CPU with a large XSAVE area exceeds the fixed 8 KB OTP 28 asks for, so the VM
# aborts at startup. erlang:28-alpine happens to be built on 3.23.5 with musl
# 1.2.5 today, but no tag of that image pins an Alpine version, so an upstream
# rebuild would break every user with such a CPU and no commit here.
#
# No erlang base is needed. mix.exs declares no `releases`, so include_erts
# defaults to true and the release carries the ERTS the builder produced. This
# image's own OTP was never executed, only its shared libraries were, and those
# are installed explicitly below.
FROM alpine:3.23

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
# libstdc++ and ncurses-libs came from the erlang base this image used to use;
# the bundled ERTS and the Rust NIFs link against them
RUN apk add --no-cache \
    sqlite \
    libpq \
    curl \
    ca-certificates \
    ffmpeg \
    chromaprint \
    fdk-aac \
    su-exec \
    tzdata \
    shadow \
    openssl \
    libstdc++ \
    ncurses-libs

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
