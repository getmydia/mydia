# Mydia

**Your personal media companion, built with Phoenix LiveView**

A modern, self-hosted media management platform for tracking, organizing, and monitoring your media library.

!!! warning "Early Development"
    Mydia is still in version 0.x.x and is subject to major changes from version to version. Feedback is welcome! Expect bugs and please open [issues](https://github.com/getmydia/mydia/issues) or [feature requests](https://github.com/getmydia/mydia/issues/new).

## Features

- **Unified Media Management** - Track both movies and TV shows with rich metadata from TMDB/TVDB
- **Automated Downloads** - Background search and download with quality profiles and smart release ranking
- **Download Clients** - qBittorrent, Transmission, SABnzbd, and NZBGet support
- **Indexer Integration** - Search via Prowlarr and Jackett for finding releases
- **Built-in Indexer Library** - Native Cardigann support (experimental, limited testing)
- **Multi-User System** - Built-in admin/guest roles with request approval workflow
- **SSO Support** - Local authentication plus OIDC/OpenID Connect integration
- **Release Calendar** - Track upcoming releases and monitor episodes
- **Import Lists** - Sync external lists from TMDB (watchlists, popular, trending) to auto-add content (experimental)
- **Remote Access** - P2P connectivity for the Flutter player via iroh (experimental)
- **Media Playback** - HLS streaming with on-the-fly transcoding (experimental)
- **Trakt.tv Integration** - Scrobbling and library sync
- **Modern Real-Time UI** - Phoenix LiveView with instant updates and responsive design

## Quick Start

Get started with Mydia in minutes using Docker Compose:

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
      - PORT=4000
      - MOVIES_PATH=/media/library/movies
      - TV_PATH=/media/library/tv
    volumes:
      - /path/to/mydia/config:/config
      - /path/to/your/media:/media
    ports:
      - 4000:4000
    restart: unless-stopped
```

Generate the required secrets:

```bash
# Generate SECRET_KEY_BASE
openssl rand -base64 48

# Generate GUARDIAN_SECRET_KEY
openssl rand -base64 48
```

For detailed setup instructions, see the [Getting Started Guide](using/tutorials/get-mydia-running.md).

## Screenshots

<div class="grid cards" markdown>

-   **Dashboard**

    ![Dashboard](https://raw.githubusercontent.com/getmydia/mydia/master/screenshots/homepage.png)

-   **Movies**

    ![Movies](https://raw.githubusercontent.com/getmydia/mydia/master/screenshots/movies.png)

-   **TV Shows**

    ![TV Shows](https://raw.githubusercontent.com/getmydia/mydia/master/screenshots/tv-shows.png)

-   **Calendar**

    ![Calendar](https://raw.githubusercontent.com/getmydia/mydia/master/screenshots/calendar.png)

</div>

## Comparison with Radarr & Sonarr

| Feature | Mydia | Radarr | Sonarr |
|---------|-------|--------|--------|
| **Media Types** | Movies + TV Shows | Movies only | TV Shows only |
| **Built-in Indexers** | Cardigann (experimental) | Requires Prowlarr/Jackett | Requires Prowlarr/Jackett |
| **Multi-User & Requests** | Built-in (admin/guest roles) | Requires Ombi/Overseerr | Requires Ombi/Overseerr |
| **Authentication** | Local + OIDC/SSO built-in | Local only | Local only |
| **Library Management** | Yes | Yes | Yes |
| **Download Automation** | Yes | Yes | Yes |
| **Quality Profiles** | Yes | Advanced | Advanced |
| **Custom Formats** | Planned | Yes | Yes |
| **Automatic Upgrades** | Planned | Yes | Yes |
| **Media Server Integration** | Planned | Plex/Kodi/Jellyfin | Plex/Kodi/Jellyfin |
| **List Import** | Experimental | Yes | Yes |
| **Native Playback** | Experimental | No | No |
| **Remote Access (P2P)** | Experimental | No | No |
| **Technology** | Elixir/Phoenix LiveView | .NET/React | .NET/React |
| **Maturity** | Early development | Production-ready | Production-ready |

**Choose Mydia for:** Unified movies+TV management, built-in multi-user support, modern real-time UI, native SSO

**Choose Radarr/Sonarr for:** Mature ecosystem, advanced custom formats, comprehensive automation, wider integrations

## Getting Help

- [GitHub Issues](https://github.com/getmydia/mydia/issues) - Bug reports and feature requests
- [Documentation](https://docs.mydia.dev) - Full documentation

## Tech Stack

- Phoenix 1.8 + LiveView
- Ecto + SQLite/PostgreSQL
- Oban (background jobs)
- Tailwind CSS + DaisyUI
- Req (HTTP client)
