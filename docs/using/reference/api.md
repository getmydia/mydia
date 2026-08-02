# API Reference

!!! info "Internal APIs"
    Mydia exposes HTTP and GraphQL APIs primarily for internal use by the Flutter player and the web UI. These APIs are not yet stable or documented for third-party consumption.

## Current State

Mydia includes several internal API surfaces used by its own components:

| Area | Description |
|------|-------------|
| **Downloads** | Download client management and status |
| **Indexers** | Search queries to configured indexers |
| **Media** | Library browsing, metadata, and management |
| **Playback** | Playback session control |
| **Streaming** | HLS streaming session lifecycle |
| **Subtitles** | Subtitle search and download |
| **Admin/Config** | Server configuration and settings |
| **GraphQL** | Absinthe-based GraphQL API (used by the Flutter player) |

## GraphQL API

The GraphQL endpoint is available at `/api/graphql` and is used by the Flutter player for:

- Browsing movies and TV shows
- Managing streaming sessions
- Fetching media metadata and files

The schema uses Absinthe with connection/edges/node pagination for collections.

## REST Endpoints

REST-style endpoints handle:

- HLS manifest and segment serving
- Subtitle file delivery
- Admin configuration

Mydia does not expose webhook endpoints. Download clients are not asked to call
back into Mydia; a background job polls each configured client for status instead.
See [The Media Pipeline](../explanation/media-pipeline.md) for how that loop works.

## Stability

These APIs are **internal** and may change between versions without notice. If you're interested in a stable public API for third-party integrations, please open a [feature request](https://github.com/getmydia/mydia/issues/new).

## Integration Options

Currently, you can integrate with Mydia through:

1. **Download Clients** - Configure in Admin UI
2. **Indexers** - Configure in Admin UI
3. **OIDC/SSO** - Authenticate via external identity providers

## Contributing

If you're interested in API development, check the [Development](../../contributing/setup.md) documentation and consider contributing to the project.

## Connection Manager

The connection manager is player-side, not a server API. It lives in the Flutter
app and decides how the player reaches your instance (direct URL, local network,
or p2p) and how it retries when a path drops. It is not documented here because
there is no HTTP surface to document; read
`player/lib/core/connection/README.md` in the repository for the implementation.
