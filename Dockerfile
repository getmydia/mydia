# ============================================
# Build Stage
# ============================================
FROM elixir:1.17-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm \
    sqlite-dev \
    curl

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

# Install runtime dependencies
RUN apk add --no-cache \
    sqlite-libs \
    curl \
    ca-certificates

# Create app user
RUN addgroup -g 1000 mydia && \
    adduser -D -u 1000 -G mydia mydia

# Create necessary directories with proper permissions
RUN mkdir -p /app /data /media && \
    chown -R mydia:mydia /app /data /media

# Set working directory
WORKDIR /app

# Copy release from builder
COPY --from=builder --chown=mydia:mydia /app/_build/prod/rel/mydia ./

# Switch to app user
USER mydia

# Set environment variables
ENV HOME=/app \
    MIX_ENV=prod \
    PHX_SERVER=true \
    DATABASE_PATH=/data/mydia.db \
    PORT=4000

# Expose HTTP port
EXPOSE 4000

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:4000/health || exit 1

# Start the application
CMD ["/app/bin/mydia", "start"]
