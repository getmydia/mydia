# Download Clients

Download clients handle the actual downloading of media files. Mydia supports both torrent and usenet clients.

## Supported Clients

Mydia supports the following client types. All are configurable via the Admin UI, environment variables, or a YAML config file.

### Torrent Clients

| Client | Type value | Protocol | Features |
|--------|------------|----------|----------|
| qBittorrent | `qbittorrent` | HTTP API | Categories, labels, seeding |
| Transmission | `transmission` | RPC | Categories, seeding |
| rqbit | `rqbit` | HTTP API | Lightweight torrent client, seeding |
| rTorrent | `rtorrent` | XML-RPC | Categories, seeding |
| Blackhole | `blackhole` | Watch directory | Drops `.torrent` files for an external client to pick up |

### Usenet Clients

| Client | Type value | Protocol | Features |
|--------|------------|----------|----------|
| SABnzbd | `sabnzbd` | HTTP API | Categories, priorities |
| NZBGet | `nzbget` | JSON-RPC | Categories, priorities |

### Debrid Services

| Client | Type value | Providers |
|--------|------------|-----------|
| Debrid | `debrid` | `real_debrid`, `all_debrid`, `premiumize`, `tor_box` |

## Adding Download Clients

### Via Admin UI

1. Navigate to **Admin > Download Clients**
2. Click **Add Download Client**
3. Select client type
4. Enter connection details
5. Test connection
6. Save

### Via Environment Variables

Configure clients at container startup:

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

# Debrid (Real-Debrid, AllDebrid, Premiumize, TorBox)
DOWNLOAD_CLIENT_7_NAME=Real-Debrid
DOWNLOAD_CLIENT_7_TYPE=debrid
DOWNLOAD_CLIENT_7_API_KEY=your-debrid-api-key
DOWNLOAD_CLIENT_7_PROVIDER=real_debrid

# Blackhole (drops .torrent files in a watched directory)
DOWNLOAD_CLIENT_8_NAME=Blackhole
DOWNLOAD_CLIENT_8_TYPE=blackhole
DOWNLOAD_CLIENT_8_WATCH_FOLDER=/downloads/watch
DOWNLOAD_CLIENT_8_COMPLETED_FOLDER=/downloads/complete
```

Every client needs a `_NAME` — Mydia discovers clients by their `_NAME`
variable, so a block without one is silently ignored.

## Configuration Options

| Option | Description | Example |
|--------|-------------|---------|
| Name | Display name | `qBittorrent` |
| Type | Client type | `qbittorrent` |
| Host | Hostname or IP | `192.168.1.100` |
| Port | Client port | `8080` |
| Username | Auth username | `admin` |
| Password | Auth password | `secret` |
| API Key | API key (SABnzbd, debrid, qBittorrent 5.2+) | `abc123` |
| Provider | Debrid provider (debrid only) | `real_debrid` |
| Use SSL | Enable HTTPS | `true` |
| Category | Default category | `mydia` |
| Priority | Client priority | `1` |
| Download Directory | Output directory | `/downloads` |

## rqbit

Mydia connects to a separately running `rqbit server` over rqbit's HTTP API. Mydia does not install, start, or supervise the rqbit process.

Use these connection values when adding rqbit:

- Type: `rqbit`
- Port: `3030` by default
- Username/password: optional, only when rqbit HTTP basic auth is enabled

rqbit supports torrents only. It does not support categories, labels, tags, or Usenet downloads, so Mydia ignores category settings for rqbit clients. Final organization still happens during import when Mydia moves or links completed files into the configured library.

## Debrid

Debrid clients connect to a hosted debrid service instead of a self-hosted daemon, so they need no host or port — only an API key and a provider.

Use these values when adding a debrid client:

- Type: `debrid`
- API Key: your account API key from the provider
- Provider: one of `real_debrid`, `all_debrid`, `premiumize`, `tor_box`

Debrid clients use a 24-hour stall-detection grace period by default (other clients use 60 minutes), because remote caching can take longer to resolve a download before it begins transferring. The provider's API endpoint is built in, so `Host`/`Port` are ignored.

A debrid provider can accept one release and still fail to fetch another: a submission that succeeds only proves your account and the API path work, not that the chosen torrent has seeds. When a provider reports a release as stalled with no seeds, Mydia keeps it active and lets the normal stall detection decide, rather than failing it immediately. TorBox in particular has not been validated against a live subscription, so please [open an issue](https://github.com/getmydia/mydia/issues) if you see behavior that differs from the above.

## Blackhole

A blackhole client writes `.torrent` files into a watched folder for a separate torrent client to pick up, then detects finished downloads in a completed folder. It uses no host or port — only the two folder paths.

Use these values when adding a blackhole client:

- Type: `blackhole`
- Watch Folder: where Mydia drops `.torrent` files (`WATCH_FOLDER`)
- Completed Folder: where the external client places finished downloads (`COMPLETED_FOLDER`)

Both folders must be readable and writable by Mydia. Final organization still happens during import when Mydia moves or links completed files into the configured library.

## Client Priority

When multiple clients are configured, priority determines which client is used:

- Higher priority = preferred
- If primary client fails, falls back to lower priority clients

## Categories

Categories help organize downloads:

- Configure a category in your download client
- Set the same category in Mydia
- Downloads are tagged with this category

rqbit does not have categories or labels. For rqbit clients, leave category fields empty and use the download directory plus Mydia's import step for final organization.

## Download Directory

Configure where downloads are saved:

- Set in download client settings
- Ensure Mydia can access this directory
- Use same filesystem as library for hardlinks

## Testing Connection

Always test connections before saving:

1. Click **Test Connection**
2. Verify successful connection
3. Check for any warnings

## Next Steps

- [Indexers](indexers.md) - Configure release searching
- [Environment Variables](../reference/environment-variables.md) - All configuration options
