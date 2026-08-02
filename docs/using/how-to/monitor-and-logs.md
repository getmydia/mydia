# Monitoring and Logs

This guide covers checking Mydia's health, wiring up a Docker health check, and viewing logs.

## Health Checks

Mydia exposes a health endpoint:

```bash
curl http://localhost:4000/health
```

## Docker Health Check

```yaml
services:
  mydia:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
```

## Logs

View container logs:

```bash
docker compose logs -f mydia
```

Configure log level:

```bash
LOG_LEVEL=debug  # or info, warning, error
```
