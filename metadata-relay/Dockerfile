# syntax=docker/dockerfile:1.4
# Digest-pinned rather than tag-pinned: the official elixir images publish no
# Alpine-qualified tag, and this stage runs the BEAM to compile, so it is
# exposed to the same musl 1.2.6 abort as the runtime stage below. This digest
# carries Alpine 3.23.5.
FROM elixir:1.20.1-alpine@sha256:f50894ff69b0d07b310fe9c97b48b3475568ecccb7f0ccd7c350a789feb395a3 AS builder

# Install build dependencies
RUN apk add --no-cache build-base git openssl-dev nodejs npm

# Set build environment
ENV MIX_ENV=prod
ENV HEX_HOME=/root/.hex
ENV MIX_HOME=/root/.mix
# Increase hex timeout for slow networks/CI (5 minutes)
ENV HEX_HTTP_TIMEOUT=300000

WORKDIR /app

# Install hex and rebar with cache
# Use id=relay-* to avoid cache contamination with mydia builds (different OTP version)
RUN --mount=type=cache,id=relay-hex,target=/root/.hex \
    --mount=type=cache,id=relay-mix,target=/root/.mix \
    mix local.hex --force && \
    mix local.rebar --force

# Copy mix files (building from repo root)
COPY metadata-relay/mix.exs metadata-relay/mix.lock ./
COPY metadata-relay/assets/package.json metadata-relay/assets/package-lock.json ./assets/

# Install dependencies with cache (with retry for transient network failures)
RUN --mount=type=cache,id=relay-hex,target=/root/.hex \
    --mount=type=cache,id=relay-mix,target=/root/.mix \
    --mount=type=cache,id=relay-deps,target=/app/deps \
    for i in 1 2 3; do \
      mix deps.get --only prod && break || \
      (echo "Attempt $i failed, retrying in 10s..." && sleep 10); \
    done && \
    cp -r deps deps_copy

# Restore deps from cache copy
RUN rm -rf deps && mv deps_copy deps

# Install frontend dependencies
RUN cd assets && npm ci

# Compile dependencies with cache
RUN --mount=type=cache,id=relay-hex,target=/root/.hex \
    --mount=type=cache,id=relay-mix,target=/root/.mix \
    --mount=type=cache,id=relay-build,target=/app/_build,sharing=locked \
    mix deps.compile && \
    cp -r _build _build_copy

# Restore _build from cache copy
RUN rm -rf _build && mv _build_copy _build

# Copy application files (building from repo root)
COPY metadata-relay/config ./config
COPY metadata-relay/assets ./assets
COPY metadata-relay/lib ./lib
COPY metadata-relay/priv ./priv

# Compile the application
RUN --mount=type=cache,id=relay-hex,target=/root/.hex \
    --mount=type=cache,id=relay-mix,target=/root/.mix \
    mix compile

# Build frontend assets
RUN --mount=type=cache,id=relay-hex,target=/root/.hex \
    --mount=type=cache,id=relay-mix,target=/root/.mix \
    mix assets.deploy

# Build release
RUN --mount=type=cache,id=relay-hex,target=/root/.hex \
    --mount=type=cache,id=relay-mix,target=/root/.mix \
    mix release

# Start a new stage for the final image
# Alpine 3.23, not 3.24, on purpose. musl 1.2.6 (Alpine 3.24) tightened
# `sigaltstack()` to reject any size below `sysconf(_SC_MINSIGSTKSZ)`, which on
# a CPU with a large XSAVE area (AVX-512, AMX) exceeds the fixed 8 KB that
# OTP 28's ERTS asks for, so the VM aborts at startup with
# "sys_sigaltstack(): Failed to set alternate signal stack". musl 1.2.5 checks
# against a static MINSIGSTKSZ instead and is unaffected.
#
# It is a musl 1.2.6 regression rather than an Alpine one, and OTP fixed its
# side in erlang/otp#11376 (merged to maint 2026-08-10), but that is not in any
# released tag yet: 28.0 through 28.5.0.5 and 29.0 through 29.0.5 all still
# hardcode SIGSTKSZ. Move this back to a current Alpine once a patch release
# carries that commit. Alpine 3.23 is supported until 2027-11-01.
#
# The tag floats within 3.23 so security patches still arrive; only the minor
# is held, and 3.23 can never carry musl 1.2.6.
FROM alpine:3.23

# Install runtime dependencies
RUN apk add --no-cache libstdc++ openssl ncurses-libs curl

# Create non-root user
RUN addgroup -g 1000 relay && \
    adduser -D -u 1000 -G relay relay

# Create data directory for SQLite database
RUN mkdir -p /data && \
    chown -R relay:relay /data

WORKDIR /app

# Copy the release from the builder stage
COPY --from=builder --chown=relay:relay /app/_build/prod/rel/metadata_relay ./

# Copy entrypoint script
COPY --chown=relay:relay metadata-relay/docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

# Set environment
ENV MIX_ENV=prod
ENV PORT=4001

# Switch to non-root user
USER relay

# Expose the port
EXPOSE 4001

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:4001/health || exit 1

# Run the application with automatic migrations
CMD ["/app/docker-entrypoint.sh"]
