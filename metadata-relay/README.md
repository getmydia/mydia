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

1. **Build the container**:
   ```bash
   docker-compose build
   ```

2. **Start the service**:
   ```bash
   docker-compose up
   ```

3. **Run in detached mode**:
   ```bash
   docker-compose up -d
   ```

4. **View logs**:
   ```bash
   docker-compose logs -f relay
   ```

5. **Stop the service**:
   ```bash
   docker-compose down
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

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PORT` | No | `4000` | HTTP port the server listens on |
| `TMDB_API_KEY` | Yes | - | API key for The Movie Database. Get one at https://www.themoviedb.org/settings/api |
| `TVDB_API_KEY` | Yes | - | API key for TheTVDB. Get one at https://thetvdb.com/api-information |

### Development Configuration

Create a `.env` file in the project root:
```bash
PORT=4001
TMDB_API_KEY=your_tmdb_key_here
TVDB_API_KEY=your_tvdb_key_here
```

The `.env.example` file provides a template with all available options.

### Production Configuration

In production (Fly.io), environment variables are managed through secrets:

```bash
# Set secrets (do not commit these!)
fly secrets set TMDB_API_KEY=your_key_here
fly secrets set TVDB_API_KEY=your_key_here

# View configured secrets (values are hidden)
fly secrets list

# Remove a secret
fly secrets unset SECRET_NAME
```

**Security Notes:**
- Never commit API keys to version control
- Use Fly.io secrets for production deployments
- API keys are loaded at runtime via `config/runtime.exs`
- Keys are not logged or exposed in health checks

## Deployment

### Fly.io Deployment

The service is designed to be deployed on Fly.io using Elixir releases.

#### Prerequisites

- Install the Fly CLI: `curl -L https://fly.io/install.sh | sh`
- Sign up and log in: `fly auth login`

#### Initial Deployment

1. **Navigate to the metadata-relay directory**:
   ```bash
   cd metadata-relay
   ```

2. **Launch the app** (first time only):
   ```bash
   fly launch --config fly.toml
   ```

   When prompted:
   - Choose a unique app name (or accept the suggested name)
   - Select a region (default: ewr - Newark, NJ)
   - Skip database creation
   - Skip deployment for now (we need to set secrets first)

3. **Set required secrets**:
   ```bash
   fly secrets set TMDB_API_KEY=your_tmdb_key_here
   fly secrets set TVDB_API_KEY=your_tvdb_key_here
   ```

4. **Deploy the application**:
   ```bash
   fly deploy
   ```

5. **Verify deployment**:
   ```bash
   fly open /health
   ```

   This should open your browser to the health check endpoint and show:
   ```json
   {
     "status": "ok",
     "service": "metadata-relay",
     "version": "0.1.0"
   }
   ```

#### Subsequent Deployments

After the initial setup, deploy updates with:
```bash
fly deploy
```

#### Monitoring

- **View logs**: `fly logs`
- **View real-time logs**: `fly logs -f`
- **Check status**: `fly status`
- **View metrics**: `fly dashboard`

#### Scaling

The default configuration runs 1 machine with 256MB RAM. To scale:

- **Scale vertically** (more resources per machine):
  ```bash
  fly scale vm shared-cpu-2x --memory 512
  ```

- **Scale horizontally** (more machines):
  ```bash
  fly scale count 2
  ```

#### Custom Domain

To use a custom domain:

1. **Add certificate**:
   ```bash
   fly certs add metadata-relay.yourdomain.com
   ```

2. **Configure DNS**: Follow the instructions provided by Fly.io

#### Troubleshooting Deployment

**Check health status:**
```bash
curl https://metadata-relay.fly.dev/health
```

**View application logs:**
```bash
# Real-time logs
fly logs -f

# Last 100 lines
fly logs --limit 100

# Filter by log level
fly logs -f | grep ERROR
```

**SSH into running machine:**
```bash
fly ssh console
```

**Check secrets configuration:**
```bash
fly secrets list
```

**Restart the application:**
```bash
fly apps restart metadata-relay
```

**Check machine status:**
```bash
fly status
fly machines list
```

**Common issues:**

1. **Deployment fails during build:**
   - Check Docker build locally: `docker build -f Dockerfile .`
   - Verify all dependencies in `mix.exs` are available
   - Check build logs: `fly logs`

2. **App crashes after deployment:**
   - Check if secrets are set: `fly secrets list`
   - View crash logs: `fly logs --limit 200`
   - Verify runtime.exs is reading environment variables correctly

3. **Health check failing:**
   - Ensure PORT environment variable matches internal_port in fly.toml
   - Check if application is listening on correct port
   - SSH in and test: `curl localhost:4001/health`

4. **Authentication errors with TMDB/TVDB:**
   - Verify API keys are set correctly: `fly secrets list`
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

## Project Structure

```
metadata-relay/
├── lib/
│   ├── metadata_relay/
│   │   ├── application.ex     # OTP application supervisor
│   │   └── router.ex          # HTTP router with Plug
│   └── metadata_relay.ex      # Main module
├── config/
│   ├── config.exs             # Base configuration
│   ├── dev.exs                # Development config
│   ├── test.exs               # Test config
│   ├── prod.exs               # Production config
│   └── runtime.exs            # Runtime environment config
├── test/
│   └── test_helper.exs        # Test configuration
├── mix.exs                    # Project definition and dependencies
├── Dockerfile                 # Container image definition
├── docker-compose.yml         # Local development setup
└── README.md                  # This file
```

## Monitoring and Logging

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

**Production (Fly.io):**
```bash
# Real-time logs
fly logs -f

# Filter by application name
fly logs -a metadata-relay

# Show errors only
fly logs -f | grep ERROR

# Export logs for analysis
fly logs --limit 1000 > relay-logs.txt
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
curl https://metadata-relay.fly.dev/health
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
- No size limit (relies on Fly.io memory constraints)
- Cache is lost on machine restart

**Recommended Monitoring:**
1. Set up Fly.io metrics monitoring for:
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

## Status

- [x] Set up project structure (task 117.1)
- [x] Implement TMDB proxy endpoints (task 117.2)
- [x] Implement TVDB proxy endpoints with authentication (task 117.3)
- [x] Add in-memory caching layer (task 117.4)
- [x] Create production Docker configuration (task 117.5)
- [x] Configure and deploy to Fly.io (task 117.6)
- [x] Update Mydia to use self-hosted relay (task 117.7)
- [x] Add monitoring, logging, and deployment documentation (task 117.8)

**Service URL**: https://metadata-relay.fly.dev

## License

Same as the main Mydia project.
