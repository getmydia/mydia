# Monitoring with Prometheus

Mydia can expose metrics for Prometheus at `/metrics`. It is off by default.

## Turn it on

Set `MYDIA_METRICS_ENABLED=true` and restart Mydia.

The endpoint has **no authentication**. Anyone who can reach it can read your
library size, download counts and which queues are busy. Scrape it over your
LAN or container network, and do not route `/metrics` through a public reverse
proxy. With Traefik, Caddy or nginx in front, block the path there.

If the player is enabled, Mydia also starts an HTTPS listener on `HTTPS_PORT`
(default 4443) that serves the same router, so `/metrics` is reachable there
too. Do not publish or forward that port while metrics are on, unless
something in front of it blocks `/metrics`.

## Scrape it

```yaml
scrape_configs:
  - job_name: mydia
    scrape_interval: 30s
    static_configs:
      - targets: ["mydia:4000"]
```

## What you get

| Metric | What it tells you |
| --- | --- |
| `mydia_build_info{version}` | The running version |
| `mydia_uptime_seconds` | Time since the last restart |
| `mydia_vm_memory_bytes{kind}` | Memory use |
| `mydia_http_request_duration_milliseconds{route,method,status_class}` | Request latency and error rate by route |
| `mydia_liveview_mounts_total{view}` | Page loads in the web UI |
| `mydia_oban_jobs{queue,state}` | Background jobs waiting, running or retrying |
| `mydia_oban_job_duration_milliseconds{queue,worker}` | How long jobs take |
| `mydia_oban_job_failures_total{queue,worker}` | Jobs that failed |
| `mydia_library_items{type}` | Movies and shows |
| `mydia_library_episodes{state,monitored}` | Downloaded, missing, upcoming and unannounced episodes |
| `mydia_library_media_files`, `mydia_library_size_bytes` | Files and bytes on disk, excluding trash |
| `mydia_downloads{state}` | Active, failed and awaiting-import downloads |
| `mydia_download_client_up{client}` | 1 when a download client's last health check passed |
| `mydia_hls_sessions{mode}`, `mydia_direct_play_sessions{kind}` | Active streams |

Gauges refresh every 15 seconds (memory, streams) or every minute (library,
downloads, jobs, client health).

## Example alerts

```yaml
- alert: MydiaDownloadClientDown
  expr: mydia_download_client_up == 0
  for: 10m
- alert: MydiaJobsRetrying
  expr: sum(mydia_oban_jobs{state="retryable"}) > 20
  for: 30m
```
