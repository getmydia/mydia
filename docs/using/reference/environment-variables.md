# Environment Variables Reference

Complete reference of all environment variables supported by Mydia.

## Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `SECRET_KEY_BASE` | Phoenix secret key for cookies/sessions | Generate with: `openssl rand -base64 48` |
| `GUARDIAN_SECRET_KEY` | JWT signing key for authentication | Generate with: `openssl rand -base64 48` |

## Container Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `PUID` | User ID for file permissions | `1000` |
| `PGID` | Group ID for file permissions | `1000` |
| `TZ` | Timezone (e.g., `America/New_York`) | `UTC` |
| `DATABASE_PATH` | Path to SQLite database file | `/config/mydia.db` |

## Server Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `PHX_HOST` | Public hostname for the application | `localhost` |
| `PORT` | HTTP server port (also used for URL generation) | `4000` |
| `HTTPS_PORT` | HTTPS server port (also used for URL generation) | `4443` |
| `HOST` | Server binding address | `0.0.0.0` |
| `URL_SCHEME` | **No effect in a container.** Accepted and validated, but a release build hardcodes its external URL to `https://{PHX_HOST}` and never reads this. | `http` |
| `PHX_CHECK_ORIGIN` | WebSocket origin checking | Allows `PHX_HOST` with any scheme |

!!! warning "URL_SCHEME does not change generated links"
    Absolute URLs, including the OIDC redirect URI, are always `https://{PHX_HOST}`
    regardless of what you set here. If you serve Mydia over plain http, set
    `OIDC_REDIRECT_URI` explicitly. See
    [SSO / OIDC](../how-to/sso-oidc.md#redirect-uri).

### Port Configuration Notes

The `PORT` and `HTTPS_PORT` environment variables serve dual purposes:
1. **Server binding** - The ports on which the HTTP and HTTPS servers listen
2. **URL generation** - Used to generate direct access URLs (e.g., sslip.io URLs for remote access)

This simplifies configuration by eliminating the need for separate port variables for URL generation.

### PHX_CHECK_ORIGIN Options

- `false` - Allow all origins (useful for IP-based access)
- Comma-separated list of allowed origins

## Media Library

| Variable | Description | Default |
|----------|-------------|---------|
| `MOVIES_PATH` | Movies directory path | `/media/movies` |
| `TV_PATH` | TV shows directory path | `/media/tv` |

### Additional Library Paths

Configure additional libraries using numbered variables (`<N>` = 1, 2, 3, etc.):

| Variable Pattern | Description | Example |
|------------------|-------------|---------|
| `LIBRARY_PATH_<N>_PATH` | Directory path | `/media/anime` |
| `LIBRARY_PATH_<N>_TYPE` | Library type | `mixed` |
| `LIBRARY_PATH_<N>_MONITORED` | Enable monitoring | `true` |
| `LIBRARY_PATH_<N>_SCAN_INTERVAL` | Automatic scan interval in seconds. Minimum 900. Omit for manual-only scanning. | `3600` |

**Library Types:** `movies`, `series`, or `mixed`

## Authentication

| Variable | Description | Default |
|----------|-------------|---------|
| `LOCAL_AUTH_ENABLED` | Enable local username/password auth | `true` |
| `OIDC_ENABLED` | Enable OIDC/OpenID Connect auth | `false` |
| `OIDC_ISSUER` | OIDC issuer URL (e.g., `https://auth.example.com`) | - |
| `OIDC_CLIENT_ID` | OIDC client ID | - |
| `OIDC_CLIENT_SECRET` | OIDC client secret | - |
| `OIDC_REDIRECT_URI` | OIDC callback URL | Auto-computed |
| `OIDC_SCOPES` | Space-separated scope list | `openid profile email` |

!!! note "Legacy Variable"
    `OIDC_DISCOVERY_DOCUMENT_URI` is accepted as a legacy alias for `OIDC_ISSUER`. The issuer is extracted by stripping the `/.well-known/openid-configuration` suffix.

## Feature Flags

| Variable | Description | Default |
|----------|-------------|---------|
| `ENABLE_PLAYBACK` | Enable media playback controls and HLS streaming | `true` |
| `ENABLE_CARDIGANN` | Enable native Cardigann indexer support | `true` |
| `ENABLE_IMPORT_LISTS` | Enable import lists for syncing external lists (TMDB watchlists, popular, etc.) | `false` |
| `ENABLE_REMOTE_ACCESS` | Enable P2P remote access for the Flutter player | `false` |

## Download Clients

Configure multiple clients using numbered variables (`<N>` = 1, 2, 3, etc.):

| Variable Pattern | Description | Example |
|------------------|-------------|---------|
| `DOWNLOAD_CLIENT_<N>_NAME` | Display name | `qBittorrent` |
| `DOWNLOAD_CLIENT_<N>_TYPE` | Client type | `qbittorrent` |
| `DOWNLOAD_CLIENT_<N>_ENABLED` | Enable this client | `true` |
| `DOWNLOAD_CLIENT_<N>_PRIORITY` | Client priority. **Lower wins**: 1 is tried before 2. | `1` |
| `DOWNLOAD_CLIENT_<N>_HOST` | Hostname or IP | `qbittorrent` |
| `DOWNLOAD_CLIENT_<N>_PORT` | Client port | `8080` |
| `DOWNLOAD_CLIENT_<N>_USE_SSL` | Use SSL/TLS | `false` |
| `DOWNLOAD_CLIENT_<N>_USERNAME` | Auth username | - |
| `DOWNLOAD_CLIENT_<N>_PASSWORD` | Auth password | - |
| `DOWNLOAD_CLIENT_<N>_API_KEY` | API key (SABnzbd, debrid, qBittorrent 5.2+) | - |
| `DOWNLOAD_CLIENT_<N>_CATEGORY` | Default category | - |
| `DOWNLOAD_CLIENT_<N>_DOWNLOAD_DIRECTORY` | Download directory | - |
| `DOWNLOAD_CLIENT_<N>_PROVIDER` | Debrid provider (debrid only) | `real_debrid` |
| `DOWNLOAD_CLIENT_<N>_WATCH_FOLDER` | Watch folder (blackhole only) | `/downloads/watch` |
| `DOWNLOAD_CLIENT_<N>_COMPLETED_FOLDER` | Completed folder (blackhole only) | `/downloads/complete` |

> `DOWNLOAD_CLIENT_<N>_NAME` is required: clients are discovered by their `_NAME` variable, so a block without it is ignored.

**Client Types:** `qbittorrent`, `transmission`, `rqbit`, `rtorrent`, `blackhole`, `sabnzbd`, `nzbget`, `debrid`

```bash
# qBittorrent
DOWNLOAD_CLIENT_1_NAME=qBittorrent
DOWNLOAD_CLIENT_1_TYPE=qbittorrent
DOWNLOAD_CLIENT_1_HOST=qbittorrent
DOWNLOAD_CLIENT_1_PORT=8080
DOWNLOAD_CLIENT_1_USERNAME=admin
DOWNLOAD_CLIENT_1_PASSWORD=adminpass
# Alternative to username/password on qBittorrent 5.2 and newer. Generate the
# key in qBittorrent under Preferences, WebUI, API Key. When set, it takes
# precedence over the username and password. qBittorrent holds exactly one
# API key at a time, so generating a new one immediately invalidates the
# previous one and breaks any other integration still using it.
# DOWNLOAD_CLIENT_1_API_KEY=qbt_yourkeyhere

# Transmission
DOWNLOAD_CLIENT_2_NAME=Transmission
DOWNLOAD_CLIENT_2_TYPE=transmission
DOWNLOAD_CLIENT_2_HOST=transmission
DOWNLOAD_CLIENT_2_PORT=9091
DOWNLOAD_CLIENT_2_USERNAME=admin
DOWNLOAD_CLIENT_2_PASSWORD=adminpass

# rqbit
DOWNLOAD_CLIENT_3_NAME=rqbit
DOWNLOAD_CLIENT_3_TYPE=rqbit
DOWNLOAD_CLIENT_3_HOST=rqbit
DOWNLOAD_CLIENT_3_PORT=3030
# Optional, when rqbit HTTP basic auth is enabled
DOWNLOAD_CLIENT_3_USERNAME=admin
DOWNLOAD_CLIENT_3_PASSWORD=adminpass

# SABnzbd
DOWNLOAD_CLIENT_4_NAME=SABnzbd
DOWNLOAD_CLIENT_4_TYPE=sabnzbd
DOWNLOAD_CLIENT_4_HOST=sabnzbd
DOWNLOAD_CLIENT_4_PORT=8080
DOWNLOAD_CLIENT_4_API_KEY=your-sabnzbd-api-key

# NZBGet
DOWNLOAD_CLIENT_5_NAME=NZBGet
DOWNLOAD_CLIENT_5_TYPE=nzbget
DOWNLOAD_CLIENT_5_HOST=nzbget
DOWNLOAD_CLIENT_5_PORT=6789
DOWNLOAD_CLIENT_5_USERNAME=nzbget
DOWNLOAD_CLIENT_5_PASSWORD=tegbzn6789

# rTorrent (uses the XML-RPC path /RPC2 by default)
DOWNLOAD_CLIENT_6_NAME=rTorrent
DOWNLOAD_CLIENT_6_TYPE=rtorrent
DOWNLOAD_CLIENT_6_HOST=rtorrent
DOWNLOAD_CLIENT_6_PORT=8080
DOWNLOAD_CLIENT_6_USERNAME=admin
DOWNLOAD_CLIENT_6_PASSWORD=adminpass
```

### Debrid Clients

Debrid clients connect to a hosted debrid service rather than a self-hosted
torrent/usenet daemon. They require `TYPE=debrid`, an `API_KEY`, and a
`PROVIDER` selecting which service to use. `HOST`/`PORT` are ignored: each
provider's API endpoint is built in.

**Providers:** `real_debrid`, `all_debrid`, `premiumize`, `tor_box`

```bash
DOWNLOAD_CLIENT_7_NAME=Real-Debrid
DOWNLOAD_CLIENT_7_TYPE=debrid
DOWNLOAD_CLIENT_7_API_KEY=your-debrid-api-key
DOWNLOAD_CLIENT_7_PROVIDER=real_debrid
```

Swap `PROVIDER` for any of the values above (e.g. `all_debrid`, `premiumize`,
`tor_box`) to use a different service. Debrid clients default to a 24-hour
stall-detection grace period (vs. 60 minutes for other clients), since remote
caching can take longer to resolve a download.

### Blackhole Clients

Blackhole clients drop `.torrent` files into a watched folder for an external
client to pick up, and detect finished downloads in a completed folder. They
require `TYPE=blackhole`, a `WATCH_FOLDER`, and a `COMPLETED_FOLDER` instead of
host/port.

```bash
DOWNLOAD_CLIENT_8_NAME=Blackhole
DOWNLOAD_CLIENT_8_TYPE=blackhole
DOWNLOAD_CLIENT_8_WATCH_FOLDER=/downloads/watch
DOWNLOAD_CLIENT_8_COMPLETED_FOLDER=/downloads/complete
```

## Indexers

Configure multiple indexers using numbered variables (`<N>` = 1, 2, 3, etc.):

| Variable Pattern | Description | Example |
|------------------|-------------|---------|
| `INDEXER_<N>_NAME` | Display name | `Prowlarr` |
| `INDEXER_<N>_TYPE` | Indexer type | `prowlarr` |
| `INDEXER_<N>_ENABLED` | Enable this indexer | `true` |
| `INDEXER_<N>_PRIORITY` | Display order only, does not affect searching | `1` |
| `INDEXER_<N>_BASE_URL` | Indexer base URL | `http://prowlarr:9696` |
| `INDEXER_<N>_API_KEY` | Indexer API key | - |
| `INDEXER_<N>_INDEXER_IDS` | Comma-separated indexer IDs | `1,2,3` |
| `INDEXER_<N>_CATEGORIES` | Comma-separated categories | `movies,tv` |
| `INDEXER_<N>_RATE_LIMIT` | Maximum requests **per minute**. Unset means no limit. | - |
| `INDEXER_<N>_TIMEOUT` | Request timeout in milliseconds | - |

**Indexer Types:** `prowlarr`, `jackett`, `nzbhydra2`, `public`

```bash
# Prowlarr
INDEXER_1_NAME=Prowlarr
INDEXER_1_TYPE=prowlarr
INDEXER_1_BASE_URL=http://prowlarr:9696
INDEXER_1_API_KEY=your-prowlarr-api-key

# Jackett
INDEXER_2_NAME=Jackett
INDEXER_2_TYPE=jackett
INDEXER_2_BASE_URL=http://jackett:9117
INDEXER_2_API_KEY=your-jackett-api-key

# NZBHydra2
INDEXER_3_NAME=NZBHydra2
INDEXER_3_TYPE=nzbhydra2
INDEXER_3_BASE_URL=http://nzbhydra2:5076
INDEXER_3_API_KEY=your-nzbhydra2-api-key
```

## Automatic Search

| Variable | Description | Default |
|----------|-------------|---------|
| `AUTO_SEARCH_MIN_SEEDERS` | Minimum seeders a result must report for an automatic search to consider it. A hard filter applied before ranking, so a torrent below it is removed rather than demoted. Manual searches have their own control, and Usenet results report no seeders and are exempt | `0` (filters nothing) |

Some indexers report zero seeders when they could not read the count rather than when a torrent is dead, so any nonzero floor can silently empty their
results. See [How Mydia decides which release to grab](../explanation/quality-decisions.md#minimum-seeders-is-a-filter-and-the-only-one-you-are-likely-to-set)
before raising it. Also settable under **Admin > Configuration > Settings > Downloads**.

## PostgreSQL Configuration

For PostgreSQL deployments (using `latest-pg` image):

| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_TYPE` | Set to `postgres` | `sqlite` |
| `DATABASE_HOST` | PostgreSQL hostname | `localhost` |
| `DATABASE_PORT` | PostgreSQL port | `5432` |
| `DATABASE_NAME` | Database name | `mydia` |
| `DATABASE_USER` | Database username | `postgres` |
| `DATABASE_PASSWORD` | Database password | - |
| `POOL_SIZE` | Connection pool size | `10` |

## Remote Access (P2P)

| Variable | Description | Default |
|----------|-------------|---------|
| `P2P_KEYPAIR_PATH` | Path to store the P2P keypair for persistent node identity | - |
| `P2P_BIND_PORT` | UDP port for direct peer-to-peer connections (enables hole punching) | Random |

!!! note
    `P2P_KEYPAIR_PATH` is required for remote access. Without it, the node ID changes on restart and paired devices can't reconnect.

## Metadata Relay

| Variable | Description | Default |
|----------|-------------|---------|
| `METADATA_RELAY_URL` | URL for the metadata relay service | `https://relay.mydia.dev` |
| `METADATA_LANGUAGE` | Language sent to TMDB/TVDB for titles, descriptions, and posters. Accepts ISO 639-1 codes (`de`) or BCP 47 tags (`de-DE`, `pt-BR`). | `en-US` |

The metadata relay proxies requests to TVDB/TMDB and handles remote access relay connections. See [Architecture](../../contributing/architecture.md) for details.

`METADATA_LANGUAGE` can also be set per-instance from **Admin > Configuration > Settings**, under **Metadata**, in the admin UI; the env var overrides the database value when both are set.

## FlareSolverr

FlareSolverr is a proxy server used to bypass Cloudflare protection on indexer sites. Used by Cardigann indexers that require browser-based challenge solving.

| Variable | Description | Default |
|----------|-------------|---------|
| `FLARESOLVERR_URL` | FlareSolverr instance URL | - |
| `FLARESOLVERR_ENABLED` | Enable FlareSolverr integration | Auto-enabled if URL is set |
| `FLARESOLVERR_TIMEOUT` | Request timeout in milliseconds | `60000` |
| `FLARESOLVERR_MAX_TIMEOUT` | Maximum timeout in milliseconds | `120000` |

## Automatic Quality Upgrades

These pace the daily upgrade sweep instance-wide. Which items it considers is set per quality profile instead; see [Quality Profiles](quality-profiles.md#upgrade-rules).

| Variable | Description | Default |
|----------|-------------|---------|
| `UPGRADE_SWEEP_ENABLED` | Master switch for the daily upgrade sweep. `false` stops all automatic upgrades without editing any profile | `true` |
| `UPGRADE_SWEEP_BATCH_SIZE` | Maximum indexer searches one sweep run may cost. Counts searches, not items: a season pack covers a whole season for one | `50` |
| `MYDIA_TRASH_DIR` | Where replaced and deleted files are moved. Must be outside every library path. Unset trashes into `.mydia-trash` beside each library | Beside each library |

See [Automatic Quality Upgrades](../how-to/automatic-quality-upgrades.md) for what these cost you in disk.

## Streaming

| Variable | Description | Default |
|----------|-------------|---------|
| `MAX_TRANSCODE_HEIGHT` | Ceiling in pixels on the output height of any transcode, for example `720`. Unset means no ceiling and a transcode keeps the source resolution | No limit |

A transcode only happens when a file's codec is not playable as-is, or when a player asks for a quality below the source. This ceiling bounds those; it never
upscales, and it does not apply when a file is streamed without re-encoding. Set it on a server that cannot encode 4K in realtime, which is what an
incompatible 4K file would otherwise ask of it. Also settable under **Admin > Configuration > Settings > Streaming**.

## Advanced Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `LOG_LEVEL` | Log level (debug, info, warning, error) | `info` |
| `SKIP_BACKUPS` | Skip the automatic database snapshot Mydia takes before applying pending migrations. SQLite only, since PostgreSQL has no automatic backup to skip. Accepts `true`, `1`, `yes`, `on` | `false` |

See [Backing Up and Restoring](../how-to/backup-restore.md) for what the automatic backup does, where it writes, and what it does not protect you from.

See [Configuration](configuration.md#configuration-precedence) for how these variables interact with database settings and the YAML config file.
