FROM elixir:1.16-alpine AS builder

# Install build dependencies
RUN apk add --no-cache build-base git

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy application files
COPY config ./config
COPY lib ./lib

# Compile the application
RUN MIX_ENV=prod mix compile

# Build release
RUN MIX_ENV=prod mix release

# Start a new stage for the final image
FROM alpine:3.19

# Install runtime dependencies
RUN apk add --no-cache libstdc++ openssl ncurses-libs curl

# Create non-root user
RUN addgroup -g 1000 relay && \
    adduser -D -u 1000 -G relay relay

WORKDIR /app

# Copy the release from the builder stage
COPY --from=builder --chown=relay:relay /app/_build/prod/rel/metadata_relay ./

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

# Run the application
CMD ["./bin/metadata_relay", "start"]
