# ============================================
# Build Stage
# ============================================
FROM elixir:1.18-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm \
    sqlite-dev \
    curl \
    ffmpeg-dev \
    fdk-aac-dev \
    pkgconfig

# Set build environment
ENV MIX_ENV=prod

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Create app directory
WORKDIR /app

# Copy dependency manifests
COPY mix.exs mix.lock ./

# Install dependencies
RUN mix deps.get --only prod && \
    mix deps.compile

# Copy application source
COPY config ./config
COPY priv ./priv
COPY lib ./lib
COPY assets ./assets

# Compile application
RUN mix compile

# Build assets
RUN cd assets && \
    npm ci --prefix . --progress=false --no-audit --loglevel=error && \
    cd .. && \
    mix assets.deploy

# Build release
RUN mix release

# ============================================
# Runtime Stage
# ============================================
FROM erlang:27-alpine

# Add OCI labels following LinuxServer.io standards
LABEL org.opencontainers.image.title="Mydia" \
      org.opencontainers.image.description="Modern, self-hosted media management platform" \
      org.opencontainers.image.url="https://github.com/getmydia/mydia" \
      org.opencontainers.image.source="https://github.com/getmydia/mydia" \
      org.opencontainers.image.vendor="Mydia" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      maintainer="Mydia"

# Install runtime dependencies including LSIO-compatible tools
RUN apk add --no-cache \
    sqlite-libs \
    curl \
    ca-certificates \
    ffmpeg \
    su-exec \
    tzdata \
    shadow

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

# Set environment variables
ENV HOME=/app \
    MIX_ENV=prod \
    PHX_SERVER=true \
    DATABASE_PATH=/config/mydia.db \
    PORT=4000 \
    PUID=1000 \
    PGID=1000 \
    TZ=UTC

# Expose HTTP port
EXPOSE 4000

# Declare volumes following LSIO conventions
VOLUME ["/config", "/data", "/media"]

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:4000/health || exit 1

# Set entrypoint and default command
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/app/bin/mydia", "start"]
