# Updating Mydia

This guide covers updating an existing Mydia installation, tracking pre-release builds, and pinning to a specific version.

## Via Docker Compose

```bash
docker compose pull
docker compose up -d
```

## Via Docker CLI

```bash
docker stop mydia
docker rm mydia
docker pull ghcr.io/getmydia/mydia:latest
# Run your docker run command again
```

Migrations run automatically on startup. Your data in `/config` is preserved.

## Testing Pre-release Builds

Mydia publishes two rolling tags: `:latest` (stable) and `:master` (rebuilds on every merge to the main branch). Track `:master` to try changes before they reach a stable release:

```yaml
services:
  mydia:
    image: ghcr.io/getmydia/mydia:master
```

The `:master` tag:

- May contain experimental features
- May have breaking changes
- Not recommended for production

Looking for the mobile app's beta programme instead? See [Remote Access](remote-access.md) for the iOS TestFlight beta.

## Version Pinning

Pin to a specific version for stability:

```yaml
services:
  mydia:
    image: ghcr.io/getmydia/mydia:1.0.0
```
