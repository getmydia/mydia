# Putting Mydia Behind a Reverse Proxy

This guide covers configuring Nginx, Traefik, or Caddy in front of Mydia, including the HTTPS, WebSocket, and origin-checking settings a reverse proxy needs.

## Reverse Proxy Configuration

### Nginx

```nginx
server {
    listen 80;
    server_name mydia.example.com;

    location / {
        proxy_pass http://localhost:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Traefik

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.mydia.rule=Host(`mydia.example.com`)"
  - "traefik.http.routers.mydia.entrypoints=websecure"
  - "traefik.http.routers.mydia.tls.certresolver=letsencrypt"
  - "traefik.http.services.mydia.loadbalancer.server.port=4000"
```

### Caddy

```caddy
mydia.example.com {
    reverse_proxy localhost:4000
}
```

## HTTPS Configuration

Configure Mydia's public hostname and URL scheme for HTTPS access and proper link generation:

```bash
PHX_HOST=mydia.example.com
URL_SCHEME=https
```

SSL termination should be handled by your reverse proxy.

## WebSocket Configuration

For LiveView real-time features to work through a reverse proxy, ensure WebSocket connections are properly proxied:

- Nginx: Include `proxy_set_header Upgrade` and `Connection "upgrade"`
- Traefik: Automatic WebSocket support
- Caddy: Automatic WebSocket support

## Origin Checking

By default, Mydia checks WebSocket origins for security. Configure as needed:

```bash
# Allow all origins (for IP-based access)
PHX_CHECK_ORIGIN=false

# Allow specific origins
PHX_CHECK_ORIGIN=https://mydia.example.com,http://192.168.1.100:4000
```

## Troubleshooting

### Connection Issues

1. Verify port mapping
2. Check firewall rules
3. Test with `curl http://localhost:4000`

## A Note on Load Balancing

Put a reverse proxy in front of *one* Mydia instance. Running several instances
behind a load balancer is not supported: background work would be duplicated,
in-memory rate limiting would be split across processes, and real-time updates
would not reach pages served by a different instance. See
[How Mydia Runs](../explanation/how-mydia-runs.md#one-instance-on-purpose).

## Next Steps

- [Backing Up and Restoring Mydia](backup-restore.md) - Mydia's actual availability story
- [How Mydia Runs](../explanation/how-mydia-runs.md) - The single-instance design and how to size it
