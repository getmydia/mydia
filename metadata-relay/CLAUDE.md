# Metadata Relay

A caching proxy service for TMDB and TVDB APIs, developed alongside Mydia but deployed separately.

## Tech Stack

- **Elixir** with **Bandit** HTTP server and **Plug** middleware
- **Req** for HTTP client, **Jason** for JSON
- **SQLite** via Ecto for persistence, **Redis** (optional) for caching
- **ErrorTracker** for error dashboard at `/errors`

## Development

```bash
# Using Docker Compose (from metadata-relay/)
docker-compose up -d

# Using local Elixir
mix deps.get
mix run --no-halt

# Tests
mix test

# Format
mix format
```

Environment variables: `PORT` (default 4001), `DASHBOARD_USERNAME` and `DASHBOARD_PASSWORD` (required in production for `/errors` and `/feedback` dashboards, and rejected if blank), `TMDB_API_KEY`, `TVDB_API_KEY`, `SUBDL_API_KEY`, `REDIS_URL` (optional).

Two more, both about how the relay identifies a caller for rate limiting:

- `RELAY_TRUSTED_PROXY_CIDRS` — comma-separated CIDRs whose `X-Forwarded-For` the relay will honour. Defaults to loopback plus RFC1918. Setting it **replaces** the default rather than adding to it, so it can be narrowed as well as widened.
- `RELAY_PROXY_RATE_LIMIT` — set to `1`/`true`/`yes`/`on` to enable the TMDB/TVDB proxy rate limit. **Off by default, deliberately.** Production sits behind Cloudflare, where the furthest hop the relay can trust is a Cloudflare edge address shared by many installs, so an enabled limiter would throttle unrelated installs against each other rather than an abuser. The real caller is in `CF-Connecting-IP`, but honouring that is only safe once Traefik's public entrypoint is restricted to Cloudflare's published ranges — until then anyone reaching the origin directly could set it and choose their own bucket. See `MetadataRelay.Plug.ProxyRateLimit`'s moduledoc for the full ordering.

## Deploying a New Version

The deployment process is tag-driven and automated via GitHub Actions.

### Steps

1. **Bump the version** in `mix.exs`:
   ```elixir
   version: "X.Y.Z"
   ```

2. **Commit the changes**:
   ```bash
   git add metadata-relay/
   git commit -m "feat(metadata-relay): prepare vX.Y.Z release"
   ```

3. **Create and push a deployment tag**:
   ```bash
   git tag metadata-relay-vX.Y.Z
   git push origin metadata-relay-vX.Y.Z
   ```

### What Happens Automatically

The `deploy-relay.yml` workflow triggers on tags matching `metadata-relay-v*` and:

1. Builds **multi-platform Docker images** (linux/amd64 + linux/arm64)
2. Pushes to **GHCR** at `ghcr.io/getmydia/mydia/metadata-relay` with semver tags (`latest`, `X.Y.Z`, `X.Y`, `X`)
3. Generates build attestations for supply chain security

### Auto-Deployment

The Kubernetes deployment (in `infra/kubernetes/apps/metadata-relay/`) has **Keel** configured to poll the GHCR registry every 5 minutes. Once the new image is pushed, Keel automatically updates the running deployment.

### CI

The `ci-relay.yml` workflow runs on every push/PR touching `metadata-relay/**` files. It checks compilation, formatting, tests, and verifies the Docker image builds.

## Project Structure

```
metadata-relay/
├── lib/
│   ├── metadata_relay/
│   │   ├── application.ex     # OTP supervisor
│   │   ├── release.ex         # Release tasks (migrations)
│   │   ├── router.ex          # HTTP router (Plug)
│   │   ├── plug/              # Cache, metrics, and other plugs
│   │   ├── subdl/             # SubDL client, subtitle handler, file id codec
│   │   ├── subtitles/         # Subtitle archive unwrapping
│   │   ├── tmdb/              # TMDB proxy handlers
│   │   └── tvdb/              # TVDB proxy handlers + auth
│   └── metadata_relay_web/    # Phoenix router for error dashboard
├── config/                    # dev, test, prod, runtime configs
├── priv/repo/migrations/      # Ecto migrations
├── Dockerfile                 # Production multi-stage build
├── Dockerfile.dev             # Development image
├── docker-compose.yml         # Local dev with optional Redis
└── mix.exs                    # Version defined here
```
