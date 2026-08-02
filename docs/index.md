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

## Where to Start

<div class="grid cards" markdown>

-   **New to Mydia**

    Follow the [Get Mydia running](using/tutorials/get-mydia-running.md) tutorial
    and have a working instance with an admin account in about 10 minutes.

-   **Have a specific task**

    The [how-to guides](using/how-to/index.md) cover installation, connecting
    clients and indexers, deployment, and everything else you do once Mydia is
    running.

-   **Looking something up**

    The [reference](using/reference/index.md) section lists environment
    variables, configuration options, and schemas.

-   **Want to know why**

    [Explanation](using/explanation/index.md) covers why Mydia works the way it
    does, including how it compares to Radarr and Sonarr.

-   **Building a plugin**

    [Building Plugins](plugins/index.md) covers the plugin sandbox, the event
    model, and how to write, test, and ship one.

-   **Contributing to Mydia**

    [Contributing](contributing/setup.md) covers the development environment,
    testing, and the codebase's architecture.

</div>

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

## Getting Help

- [GitHub Issues](https://github.com/getmydia/mydia/issues) - Bug reports and feature requests
- [Documentation](https://docs.mydia.dev) - Full documentation

## Tech Stack

- Phoenix 1.8 + LiveView
- Ecto + SQLite/PostgreSQL
- Oban (background jobs)
- Tailwind CSS + DaisyUI
- Req (HTTP client)
