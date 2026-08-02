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

## Background Jobs

Most of what Mydia does on your behalf (scans, metadata refreshes, download
monitoring, imports) runs as a background job rather than in a request. When
something is not happening and the logs are quiet, **Admin > Background Jobs**
shows the queues, what is running, and what failed.

## Next Steps

- [Updating Mydia](update-mydia.md) - what to watch in the logs during an upgrade
- [Backing Up and Restoring](backup-restore.md) - what the automatic pre-migration copy does and does not cover
- [Managing Libraries](manage-libraries.md) - when a scan finds nothing, the path is the usual culprit
- [Environment Variables](../reference/environment-variables.md) - `LOG_LEVEL` and the rest
