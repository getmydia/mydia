# syntax=docker/dockerfile:1.4
FROM elixir:1.20.1-alpine AS builder

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
FROM alpine:3.24.1

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
