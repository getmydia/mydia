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

Environment variables: `PORT` (default 4001), `SECRET_KEY_BASE` (optional; a random key is generated per boot if unset, so sessions do not survive a restart), `DASHBOARD_USERNAME` and `DASHBOARD_PASSWORD` (required in production unless `DASHBOARD_GITHUB_ORG` is set), `DASHBOARD_GITHUB_ORG` (a GitHub organization login; setting this switches `/errors` and `/feedback` from basic auth to GitHub App sign-in by active members of that org, and disables basic auth), `GITHUB_APP_CLIENT_ID` and `GITHUB_APP_CLIENT_SECRET` (the "Mydia Relay" GitHub App), `FEEDBACK_GITHUB_REPO` (default `getmydia/mydia`), `TMDB_API_KEY`, `TVDB_API_KEY`, `SUBDL_API_KEY`, `REDIS_URL` (optional).

The two dashboard access modes are mutually exclusive. With `DASHBOARD_GITHUB_ORG` set, GitHub sign-in is the only way in and the feedback dashboard can file issues as the signed-in maintainer. With it empty, basic auth applies and the issue-filing button is hidden.

Access follows organization membership, so there is no list of logins to maintain: adding someone to the org grants the dashboards, removing them takes it away. Only an `active` membership counts, since a pending invitation would otherwise be enough to get in. Membership is a remote lookup rather than config, so it is checked at sign-in and re-checked at most every five minutes; a removed member keeps a live session until that window passes. When GitHub cannot be reached the existing session is left alone rather than signed out, so an outage at GitHub does not lock a maintainer out of the dashboards.

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
