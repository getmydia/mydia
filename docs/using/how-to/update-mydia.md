# Updating Mydia

This guide covers updating an existing Mydia installation, tracking pre-release builds, and pinning to a specific version.

!!! warning "Back up before you upgrade"
    Mydia applies pending migrations on startup. On SQLite it copies the database
    file first, beside the original, which covers a migration going wrong but not
    the disk it lives on. On PostgreSQL it takes no backup at all. Take your own
    before pulling a new image. See
    [Backing Up and Restoring](backup-restore.md).

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

Migrations run automatically on startup, after Mydia copies the SQLite database
(see [Backing Up and Restoring](backup-restore.md)). Your data in `/config` is
preserved.

## Testing Pre-release Builds

Mydia publishes two rolling tags: `:latest` (stable) and `:master` (rebuilds on every merge to the main branch). Track `:master` to try changes before they reach a stable release:

```yaml
services:
  mydia:
    image: ghcr.io/getmydia/mydia:master
```

PostgreSQL users need the `-pg` variant, exactly as with the stable tags:

```yaml
services:
  mydia:
    image: ghcr.io/getmydia/mydia:master-pg
```

!!! warning "`:master` is amd64 only"
    The `:master` and `:master-pg` builds are `linux/amd64` and nothing else. They
    will not run on a Raspberry Pi, an arm64 server, or Apple Silicon. Only tagged
    releases are built multi-arch, so on arm64 hardware you are limited to `:latest`,
    `:beta`, or a pinned version.

The `:master` tag:

- May contain experimental features
- May have breaking changes
- Not recommended for production
- Is not covered by release notes, so read the commit log if something changes under you

If you want pre-release builds on arm64, use `:beta` (or `:beta-pg`), which is
published from tagged pre-releases and is multi-arch.

Looking for the mobile app's beta programme instead? See [Remote Access](remote-access.md) for the iOS TestFlight beta.

## Version Pinning

Pin to a specific version for stability:

```yaml
services:
  mydia:
    image: ghcr.io/getmydia/mydia:1.0.0
```

Pinned tags come in both database flavours (`1.0.0` for SQLite, `1.0.0-pg` for
PostgreSQL) and both are multi-arch. Partial pins work too: `1.0` follows the
latest patch on that minor, and `1` follows the latest release in that major.
