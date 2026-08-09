# Mydia

[![CI](https://github.com/getmydia/mydia/actions/workflows/ci.yml/badge.svg)](https://github.com/getmydia/mydia/actions/workflows/ci.yml)
[![Documentation](https://github.com/getmydia/mydia/actions/workflows/ci-docs.yml/badge.svg)](https://docs.mydia.dev)
[![TestFlight](https://img.shields.io/badge/TestFlight-Join%20iOS%20Beta-0D96F6?logo=apple&logoColor=white)](https://testflight.apple.com/join/KFSYxaQP)

**Your personal media companion, built with Phoenix LiveView**

A modern, self-hosted media management platform for tracking, organizing, and monitoring your movies and TV shows.

> **Warning:** Mydia is in early development (0.x.x). Expect breaking changes. [Report issues](https://github.com/getmydia/mydia/issues) or [request features](https://github.com/getmydia/mydia/issues/new).

<p align="center">
  <img src="screenshots/homepage.png" alt="Mydia Dashboard" width="800" />
</p>

## Quick Start

**1. Generate secrets:**

```bash
openssl rand -base64 48  # SECRET_KEY_BASE
openssl rand -base64 48  # GUARDIAN_SECRET_KEY
```

**2. Create `docker-compose.yml`:**

```yaml
services:
  mydia:
    image: ghcr.io/getmydia/mydia:latest
    container_name: mydia
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
      - SECRET_KEY_BASE=your-secret-key-base-here
      - GUARDIAN_SECRET_KEY=your-guardian-secret-key-here
      - PHX_HOST=localhost
      - MOVIES_PATH=/media/library/movies
      - TV_PATH=/media/library/tv
    volumes:
      - ./config:/config
      - /path/to/media:/media
    ports:
      - 4000:4000
    restart: unless-stopped
```

**3. Start and access:**

```bash
docker compose up -d
```

Open http://localhost:4000 and create your admin account.

## Features

- **Unified Media Management** - Movies + TV shows with TMDB/TVDB metadata
- **Automated Downloads** - Quality profiles, smart release ranking
- **Download Clients** - qBittorrent, Transmission, rqbit, SABnzbd, NZBGet, debrid providers
- **Indexers** - Prowlarr, Jackett, built-in Cardigann (experimental)
- **Multi-User** - Admin/guest roles with request workflow
- **SSO** - Local auth + OIDC/OpenID Connect
- **Import Lists** - Sync from TMDB watchlists, popular, trending (experimental)
- **Real-Time UI** - Phoenix LiveView with instant updates

## Mydia Player

A cross-platform app that streams your library from anywhere over an encrypted
peer-to-peer connection. No port forwarding, no VPN.

| Platform | Get it | Notes |
|---|---|---|
| Android | [Download APK](https://mydia.dev/download/android) | Allow installs from unknown sources |
| iOS | [Join the TestFlight beta](https://testflight.apple.com/join/KFSYxaQP) | Needs the TestFlight app |
| macOS | [Download .dmg](https://mydia.dev/download/macos) | Notarized, updates itself |
| Windows | [Download installer](https://mydia.dev/download/windows) | Per-user install, unsigned build |
| Linux | [Flatpak](https://mydia.dev/download/flatpak) or [.tar.gz](https://mydia.dev/download/linux) | Flatpak recommended |
| Web | Served by your own Mydia server at `/player` | Nothing to install |

**[All platforms and install instructions](https://mydia.dev/download)**

## Documentation

Full documentation available at **[docs.mydia.dev](https://docs.mydia.dev)**

- [Tutorials](https://docs.mydia.dev/latest/using/tutorials/) - get Mydia running from scratch
- [How-to guides](https://docs.mydia.dev/latest/using/how-to/) - install, connect clients and indexers, deploy
- [Reference](https://docs.mydia.dev/latest/using/reference/) - environment variables, configuration, database, API
- [Explanation](https://docs.mydia.dev/latest/using/explanation/) - how Mydia works and why
- [Contributing](https://docs.mydia.dev/latest/contributing/setup/) - development setup

## Screenshots

| Movies | TV Shows | Calendar |
|:------:|:--------:|:--------:|
| ![Movies](screenshots/movies.png) | ![TV Shows](screenshots/tv-shows.png) | ![Calendar](screenshots/calendar.png) |

## Contributing

```bash
./dev up -d              # Start development environment
./dev mix ecto.migrate   # Run migrations
./dev mix test           # Run tests
./dev mix precommit      # Run all checks
```

See the [Development Guide](https://docs.mydia.dev/latest/contributing/setup/) for details.

### Documentation

Docs are built with [MkDocs](https://www.mkdocs.org/) and [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/). Requires [uv](https://docs.astral.sh/uv/).

```bash
uv sync --project docs            # Install dependencies
uv run --project docs mkdocs serve   # Serve at http://localhost:8000
uv run --project docs mkdocs build   # Build static site to /site
```

## License

Built with Elixir & Phoenix
