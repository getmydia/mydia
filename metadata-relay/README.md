# Metadata Relay Service

A caching proxy service for TMDB and TVDB APIs built with Elixir, Plug, and Bandit.

## Overview

The Metadata Relay Service acts as an intermediary between the Mydia application and external metadata providers (TMDB and TVDB). It provides:

- **Caching**: Reduces API calls to external services and improves response times
- **Rate Limiting Protection**: Prevents hitting API rate limits
- **API Key Management**: Centralizes API key handling
- **High Performance**: Built on Bandit HTTP server for excellent throughput

## Technology Stack

- **Elixir**: Functional programming language with OTP supervision
- **Bandit**: Fast, lightweight HTTP/1.1 and HTTP/2 server
- **Plug**: Composable web middleware
- **Req**: Modern HTTP client
- **Cachex**: Powerful in-memory caching with TTL and LRU
- **Jason**: JSON encoding/decoding

## Local Development

### Prerequisites

- Elixir 1.14 or later
- Erlang/OTP 25 or later
- Docker and Docker Compose (alternative to local Elixir install)

### Using Docker (Recommended)

The Docker Compose configuration includes an optional Redis service for persistent caching. By default, Redis is enabled.

**With Redis (default):**

1. **Start all services**:

   ```bash
   docker-compose up -d
   ```

   This starts both the relay service and Redis.

2. **View logs**:

   ```bash
   docker-compose logs -f relay
   ```

3. **Stop all services**:
   ```bash
   docker-compose down
   ```

**Without Redis (in-memory cache only):**

To use in-memory caching instead of Redis:

1. **Edit docker-compose.yml** and comment out:

   - The `REDIS_URL` environment variable in the relay service
   - The entire `redis` service
   - The `depends_on: redis` line
   - The `redis_data` volume

2. **Start the service**:
   ```bash
   docker-compose up -d
   ```

**Accessing Redis directly:**

Redis is exposed on port 6379. You can connect using `redis-cli`:

```bash
docker-compose exec redis redis-cli

# View cache keys
KEYS metadata_relay:*

# View cache stats
INFO stats
```

### Using Local Elixir

1. **Install dependencies**:

   ```bash
   mix deps.get
   ```

2. **Run the server**:

   ```bash
   mix run --no-halt
   ```

3. **Run with iex (interactive shell)**:
   ```bash
   iex -S mix
   ```

### Testing

Run the test suite:

```bash
mix test
```

Run tests with coverage:

```bash
mix test --cover
```

### Code Formatting

Format code according to project standards:

```bash
mix format
```

## Configuration

The service is configured entirely via environment variables for maximum flexibility and security.

### Environment Variables

| Variable          | Required | Default            | Description                                                                                                             |
| ----------------- | -------- | ------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| `PORT`            | No       | `4001`             | HTTP port the server listens on                                                                                         |
| `TMDB_API_KEY`    | Yes      | -                  | API key for The Movie Database. Get one at https://www.themoviedb.org/settings/api                                      |
| `TVDB_API_KEY`    | Yes      | -                  | API key for TheTVDB. Get one at https://thetvdb.com/api-information                                                     |
| `REDIS_URL`       | No       | -                  | Redis connection URL for persistent caching. Format: `redis://[password@]host:port`. If not set, uses in-memory caching |
| `FEEDBACK_EMAIL_TO` | No     | -                  | Email address that receives a notification for each new feedback submission. Notifications are disabled when unset       |
| `FEEDBACK_EMAIL_FROM` | No   | `metadata-relay@localhost` | Sender address for feedback notification emails                                                                   |
| `FEEDBACK_DASHBOARD_URL` | No | -                 | Public dashboard base URL included in feedback notification emails, for example `https://relay.example.com`             |
| `SMTP_HOST`       | Required when `FEEDBACK_EMAIL_TO` is set in production | - | SMTP relay host used to send feedback notification emails                                                       |
| `SMTP_PORT`       | No       | `587`              | SMTP relay port                                                                                                         |
| `SMTP_USERNAME`   | No       | -                  | SMTP username. SMTP auth is enabled when both username and password are present                                          |
| `SMTP_PASSWORD`   | No       | -                  | SMTP password. SMTP auth is enabled when both username and password are present                                          |
| `P2P_ACCESS_BEARER_TOKENS` | No | -                | Comma-separated list of bearer tokens the self-hosted iroh relay may present to `POST /p2p/access`. Multiple values are accepted so a token can be rotated by deploying the new one alongside the old and removing the old afterwards. Unset means the endpoint denies every relay client |

### Cache Configuration

The metadata relay supports two caching backends:

#### In-Memory Cache (Default)

**When to use:**

- Local development
- Single-instance deployments
- When Redis is not available

**Characteristics:**

- Fast, zero-latency access
- Cache lost on service restart
- Limited by available RAM
- Maximum 20,000 entries with LRU eviction

**Configuration:**

- No configuration needed
- Simply don't set `REDIS_URL`

#### Redis Cache (Optional)

**When to use:**

- Production deployments
- Multi-instance/horizontal scaling
- When cache persistence across restarts is needed
- When sharing cache between multiple services

**Characteristics:**

- Persistent cache across restarts
- Shared cache for multiple instances
- Configurable eviction policies
- Network latency overhead

**Configuration:**
Set the `REDIS_URL` environment variable:

```bash
# Standard Redis
REDIS_URL=redis://localhost:6379

# Redis with password
REDIS_URL=redis://password@localhost:6379

# Redis with username and password
REDIS_URL=redis://username:password@localhost:6379
```

**Fallback behavior:**

- If Redis connection fails at startup, service falls back to in-memory cache
- Service continues to operate normally with degraded caching
- Connection failures are logged but don't crash the service

### Development Configuration

Create a `.env` file in the project root:

**Without Redis (default):**

```bash
PORT=4001
TMDB_API_KEY=your_tmdb_key_here
TVDB_API_KEY=your_tvdb_key_here
```

**With Redis:**

```bash
PORT=4001
TMDB_API_KEY=your_tmdb_key_here
TVDB_API_KEY=your_tvdb_key_here
REDIS_URL=redis://localhost:6379
```

The `.env.example` file provides a template with all available options.

### Cache TTL and Eviction Policies

The service automatically determines cache TTL based on content type:

| Content Type                | TTL     | Rationale                                |
| --------------------------- | ------- | ---------------------------------------- |
| Movie/TV show details by ID | 30 days | Metadata rarely changes once published   |
| Images                      | 90 days | Image URLs never change                  |
| Season/episode data         | 14 days | Episode data is stable once aired        |
| Search results              | 7 days  | Search results change occasionally       |
| Trending content            | 1 hour  | Trending data changes frequently         |
| Default                     | 30 days | Conservative default for other endpoints |

**In-Memory Cache Eviction:**

- Maximum entries: 20,000
- Eviction policy: LRU (Least Recently Used)
- Background cleanup: Every 15 minutes

**Redis Cache Eviction:**

- TTL-based expiration (automatic)
- No size limits (managed by Redis configuration)
- Configurable via Redis `maxmemory-policy` setting

### Production Configuration

In production, environment variables are managed through the Kubernetes manifests
in `infra/kubernetes/apps/metadata-relay/` — non-secret config in `configmap.yaml`,
credentials in a `secret.yaml` generated from `secret.yaml.example` and applied
with `kubectl apply -f secret.yaml`. See that directory's README for the full
setup and troubleshooting procedure.

**Security Notes:**

- Never commit API keys to version control (`secret.yaml` is git-ignored)
- Use Kubernetes secrets for production deployments
- API keys are loaded at runtime via `config/runtime.exs`
- Keys are not logged or exposed in health checks

## Deployment

### Automated Deployments (Recommended)

The metadata-relay service uses GitHub Actions for automated CI/CD. When you push a version tag, it automatically:

1. ✅ Runs tests and builds the Docker image
2. 📦 Pushes the image to GitHub Container Registry (GHCR)
3. 🚀 Makes the new image available for your deployment target to roll out

#### Creating a Deployment Build

To publish a new deployable image:

1. **Update the version** in `mix.exs` (if desired):

   ```elixir
   def project do
     [
       version: "0.2.0",  # Bump this version
       # ...
     ]
   end
   ```

2. **Commit your changes**:

   ```bash
   git add .
   git commit -m "feat: prepare metadata-relay v0.2.0 release"
   ```

3. **Create and push a version tag**:

   ```bash
   # Format: metadata-relay-vX.Y.Z
   git tag metadata-relay-v0.2.0
   git push origin metadata-relay-v0.2.0
   ```

4. **Monitor the deployment build**:
   - Go to GitHub Actions to watch the build and deployment
   - Your deployment target can pull the new image once it is published

#### Prerequisites for Automated Deployments

No extra deployment secret is required for the GitHub workflow itself. It only needs the default `GITHUB_TOKEN` to publish the metadata-relay image to GHCR.

In production, the relay is rolled out separately by infrastructure automation after the new image is published.

**Validate your setup:**

```bash
# Run the validation script to check everything is configured
cd metadata-relay
./scripts/validate-release-setup.sh
```

**Helpful commands:**

```bash
# Monitor a deployment build in real-time
gh run watch

# View recent workflow runs
gh run list --workflow=deploy-relay.yml
```

#### What Gets Built

Each deployment build creates multi-platform Docker images:

- **Platforms**: `linux/amd64`, `linux/arm64`
- **Registry**: GitHub Container Registry (GHCR)
- **Tags**: `latest`, `X.Y.Z`, `X.Y`, `X` (semantic versioning)
- **Access**: `docker pull ghcr.io/getmydia/mydia/metadata-relay:latest`

### Manual Kubernetes Deployment

Production runs on Kubernetes via the manifests in
`infra/kubernetes/apps/metadata-relay/` (namespace `metadata-relay`, deployment
`metadata-relay`, served at `https://relay.mydia.dev`). New images published to
GHCR are picked up automatically by [Keel](https://keel.sh/), so a manual
deployment is only needed for initial setup or troubleshooting.

See `infra/kubernetes/apps/metadata-relay/README.md` for the full quick-start,
secret setup, updating, and troubleshooting procedure (`kubectl apply -k .`,
`kubectl logs`, `kubectl rollout restart`, etc.).

**Common issues:**

1. **Deployment fails during build:**

   - Check Docker build locally, from the repo root (the Dockerfile `COPY`s
     from `metadata-relay/...`, so it needs the repo root as build context):
     `docker build -f metadata-relay/Dockerfile .`
   - Verify all dependencies in `mix.exs` are available
   - Check the GitHub Actions build logs for `deploy-relay.yml`

2. **App crashes after deployment:**

   - Check pod status: `kubectl describe pod -n metadata-relay -l app.kubernetes.io/name=metadata-relay`
   - View logs: `kubectl logs -n metadata-relay -l app.kubernetes.io/name=metadata-relay`
   - Verify `runtime.exs` is reading environment variables correctly

3. **Health check failing:**

   - Ensure `PORT` in `configmap.yaml` matches the container port the deployment expects
   - Check if the application is listening on the correct port
   - Exec in and test: `kubectl exec -n metadata-relay deploy/metadata-relay -- curl localhost:4001/health`

4. **Authentication errors with TMDB/TVDB:**
   - Verify API keys are set correctly in `secret.yaml`
   - Test keys locally first
   - Check for key expiration or quota limits

## API Endpoints

### Health Check

```
GET /health
```

Returns service status and version:

```json
{
  "status": "ok",
  "service": "metadata-relay",
  "version": "0.1.0"
}
```

### TMDB Endpoints

All TMDB endpoints support query parameters compatible with the TMDB API.

- `GET /configuration` - TMDB configuration
- `GET /tmdb/movies/search?query=...` - Search movies
- `GET /tmdb/tv/search?query=...` - Search TV shows
- `GET /tmdb/movies/:id` - Get movie details
- `GET /tmdb/tv/shows/:id` - Get TV show details
- `GET /tmdb/movies/:id/images` - Get movie images
- `GET /tmdb/tv/shows/:id/images` - Get TV show images
- `GET /tmdb/tv/shows/:id/:season` - Get season details
- `GET /tmdb/movies/trending` - Get trending movies
- `GET /tmdb/tv/trending` - Get trending TV shows

### TVDB Endpoints

All TVDB endpoints support query parameters compatible with the TVDB API v4.

- `GET /tvdb/search?query=...` - Search series
- `GET /tvdb/series/:id` - Get series details
- `GET /tvdb/series/:id/extended` - Get extended series details
- `GET /tvdb/series/:id/episodes` - Get series episodes
- `GET /tvdb/seasons/:id` - Get season details
- `GET /tvdb/seasons/:id/extended` - Get extended season details
- `GET /tvdb/episodes/:id` - Get episode details
- `GET /tvdb/episodes/:id/extended` - Get extended episode details
- `GET /tvdb/artwork/:id` - Get artwork details

### Error Tracking Dashboard

The metadata-relay includes an integrated error tracking dashboard powered by ErrorTracker:

```
GET /errors
```

**Features:**

- View all errors and exceptions from the metadata-relay service
- See crash reports submitted by Mydia instances
- Browse error details including stacktraces and context
- Group similar errors together
- Track error frequency and trends

**Access:** Navigate to `https://your-metadata-relay-domain.com/errors` in your browser.

**Note:** Database migrations run automatically on container startup, so the dashboard is available immediately after deployment.

### Crash Report Ingestion

Mydia instances can submit crash reports to the metadata-relay:

```
POST /crashes/report
```

**Request body:**

```json
{
  "error_type": "RuntimeError",
  "error_message": "Something went wrong",
  "stacktrace": [{ "file": "lib/mydia.ex", "line": 42, "function": "process" }],
  "version": "1.0.0",
  "environment": "production",
  "occurred_at": "2025-11-19T23:00:00Z",
  "metadata": {}
}
```

**Rate limiting:** 10 requests per minute per IP address.

## Project Structure

```
metadata-relay/
├── lib/
│   ├── metadata_relay/
│   │   ├── application.ex     # OTP application supervisor
│   │   ├── release.ex         # Release tasks (migrations)
│   │   └── router.ex          # HTTP router with Plug
│   ├── metadata_relay_web/
│   │   ├── components/
│   │   │   └── layouts/       # Error page templates
│   │   └── router.ex          # Phoenix router for dashboard
│   └── metadata_relay.ex      # Main module
├── config/
│   ├── config.exs             # Base configuration
│   ├── dev.exs                # Development config
│   ├── test.exs               # Test config
│   ├── prod.exs               # Production config
│   └── runtime.exs            # Runtime environment config
├── priv/
│   └── repo/
│       └── migrations/        # Database migrations
├── test/
│   └── test_helper.exs        # Test configuration
├── mix.exs                    # Project definition and dependencies
├── Dockerfile                 # Container image definition
├── docker-entrypoint.sh       # Startup script with auto-migrations
├── docker-compose.yml         # Local development setup
└── README.md                  # This file
```

## Monitoring and Logging

### Error Tracking

The metadata-relay includes integrated error tracking with the ErrorTracker dashboard:

- **Dashboard URL**: `https://your-domain.com/errors`
- **Automatic setup**: Database migrations run automatically on container startup
- **Features**:
  - Track all errors and exceptions from the relay service
  - Receive and view crash reports from Mydia instances
  - Browse error details with full stacktraces
  - Group similar errors together
  - Monitor error frequency and trends

### Application Logging

The service uses Elixir's built-in Logger for structured logging. Logs include:

- **Request/Response Logging**: Automatic via `Plug.Logger`

  - HTTP method, path, status code
  - Response time
  - Client IP address

- **Cache Events**: Logged by `MetadataRelay.Plug.Cache`

  - Cache hits (`:debug` level)
  - Cache misses (`:debug` level)
  - Cache key generation
  - TTL information

- **TVDB Authentication**: Logged by `MetadataRelay.TVDB.Auth`

  - Token generation (`:info` level)
  - Token refresh (`:info` level)
  - Authentication failures (`:error` level)

- **Error Logging**:
  - HTTP errors with status codes and response bodies
  - Network failures with retry attempts
  - Authentication failures with context

### Log Levels

The service uses standard Elixir log levels:

- `:debug` - Detailed information for diagnosing issues (cache events, request details)
- `:info` - General informational messages (startup, authentication events)
- `:warning` - Warning messages (retry attempts, deprecated features)
- `:error` - Error conditions (failed requests, authentication failures)

### Viewing Logs

**Local development:**

```bash
# Logs appear in console when running with mix
mix run --no-halt

# Or in iex
iex -S mix
```

**Docker:**

```bash
docker-compose logs -f relay
```

**Production (Kubernetes):**

```bash
# Real-time logs
kubectl logs -n metadata-relay -l app.kubernetes.io/name=metadata-relay -f

# Show errors only
kubectl logs -n metadata-relay -l app.kubernetes.io/name=metadata-relay -f | grep ERROR

# Export logs for analysis
kubectl logs -n metadata-relay -l app.kubernetes.io/name=metadata-relay --tail=1000 > relay-logs.txt
```

### Metrics and Telemetry

The service is instrumented with Elixir's Telemetry library for metrics collection.

**Available Telemetry Events:**

- `[:plug, :router_dispatch, :start]` - Request start
- `[:plug, :router_dispatch, :stop]` - Request complete (includes duration)
- `[:plug, :router_dispatch, :exception]` - Request exception

**Key Metrics to Monitor:**

1. **Request Rate**: Number of requests per second
2. **Response Time**: P50, P95, P99 latencies
3. **Error Rate**: 4xx and 5xx responses
4. **Cache Hit Ratio**: Percentage of requests served from cache
5. **TVDB Token Refresh**: Frequency of token regeneration

### Health Checks

The `/health` endpoint provides basic service status:

```bash
curl https://relay.mydia.dev/health
```

Response:

```json
{
  "status": "ok",
  "service": "metadata-relay",
  "version": "0.1.0"
}
```

A `200 OK` status indicates the service is running and able to respond to requests.

### Performance Monitoring

**Cache Performance:**

- Cache is stored in-memory using ETS
- Default TTL: 1 hour
- No size limit (relies on the pod's memory limit — 512Mi by default, see `deployment.yaml`)
- Cache is lost on pod restart

**Recommended Monitoring:**

1. Set up metrics monitoring for:

   - CPU usage
   - Memory usage
   - Request latency
   - HTTP status codes

2. Configure alerts for:

   - High error rates (>5% 5xx responses)
   - Slow response times (P95 > 1s)
   - Memory usage >80%
   - Machine crashes/restarts

3. Monitor upstream APIs:
   - TMDB API quota and rate limits
   - TVDB API quota and rate limits

## Development Workflow

1. Make changes to source files in `lib/`
2. Run `mix format` to format code
3. Run `mix test` to ensure tests pass
4. Test manually by running the server and making HTTP requests
5. Check logs for any warnings or errors
6. Verify cache behavior for frequently accessed endpoints

## Continuous Integration

The project uses GitHub Actions for automated testing and quality checks:

### CI Workflow (Runs on every push/PR)

Automatically runs on changes to the `metadata-relay/` directory:

- ✅ **Tests**: Full test suite with coverage reporting
- 🔍 **Code Quality**: Unused dependency checks, compilation warnings check
- 📝 **Formatting**: Ensures code follows project standards
- 🐳 **Docker Build**: Verifies Docker image builds successfully

### Deployment Workflow (Runs on version tags)

Triggered when pushing tags matching `metadata-relay-v*`:

- 🏗️ **Build**: Creates multi-platform Docker images (amd64, arm64)
- 📦 **Publish**: Pushes to GitHub Container Registry
- 🚀 **Deploy**: Makes a new semver-tagged image available for infrastructure automation to roll out

All workflows must pass before code can be merged, ensuring production stability.

## Status

- [x] Set up project structure (task 117.1)
- [x] Implement TMDB proxy endpoints (task 117.2)
- [x] Implement TVDB proxy endpoints with authentication (task 117.3)
- [x] Add in-memory caching layer (task 117.4)
- [x] Create production Docker configuration (task 117.5)
- [x] Configure and deploy to Fly.io (task 117.6)
- [x] Update Mydia to use self-hosted relay (task 117.7)
- [x] Add monitoring, logging, and deployment documentation (task 117.8)

**Service URL**: https://relay.mydia.dev

## License

Same as the main Mydia project.
