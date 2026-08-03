# Download Clients

Download clients handle the actual downloading of media files. Mydia supports both torrent and usenet clients.

See [Download Clients](../reference/download-clients.md) for the full list of supported client types.

## Adding Download Clients

### Via Admin UI

1. Navigate to **Admin > Configuration**, then the **Clients** tab
2. Click **New**
3. Select client type
4. Enter connection details
5. Test connection
6. Save

### Via Environment Variables

Every download client variable is listed in [Environment variables](../reference/environment-variables.md#download-clients).

See [Download Clients Reference](../reference/download-clients.md#configuration-fields) for the full list of Admin UI configuration fields.

## qBittorrent

qBittorrent is one of the most common torrent clients paired with Mydia. Use these connection values when adding it:

- Type: `qbittorrent`
- Host: your qBittorrent hostname or IP (for example, `qbittorrent` if it runs as a linked container)
- Port: `8080` by default
- Username/Password: your qBittorrent Web UI credentials

## rqbit

Mydia connects to a separately running `rqbit server` over rqbit's HTTP API. Mydia does not install, start, or supervise the rqbit process.

Use these connection values when adding rqbit:

- Type: `rqbit`
- Port: `3030` by default
- Username/password: optional, only when rqbit HTTP basic auth is enabled

rqbit supports torrents only. It does not support categories, labels, tags, or Usenet downloads, so Mydia ignores category settings for rqbit clients. Final organization still happens during import when Mydia moves or links completed files into the configured library.

## Debrid

Debrid clients connect to a hosted debrid service instead of a self-hosted daemon, so they need no host or port, only an API key and a provider.

Use these values when adding a debrid client:

- Type: `debrid`
- API Key: your account API key from the provider
- Provider: one of `real_debrid`, `all_debrid`, `premiumize`, `tor_box`

Debrid clients use a 24-hour stall-detection grace period by default (other clients use 60 minutes), because remote caching can take longer to resolve a download before it begins transferring. The provider's API endpoint is built in, so `Host`/`Port` are ignored.

A debrid provider can accept one release and still fail to fetch another: a submission that succeeds only proves your account and the API path work, not that the chosen torrent has seeds. When a provider reports a release as stalled with no seeds, Mydia keeps it active and lets the normal stall detection decide, rather than failing it immediately. TorBox in particular has not been validated against a live subscription, so please [open an issue](https://github.com/getmydia/mydia/issues) if you see behavior that differs from the above.

## Blackhole

A blackhole client writes `.torrent` files into a watched folder for a separate torrent client to pick up, then detects finished downloads in a completed folder. It uses no host or port, only the two folder paths.

Use these values when adding a blackhole client:

- Type: `blackhole`
- Watch Folder: where Mydia drops `.torrent` files (`WATCH_FOLDER`)
- Completed Folder: where the external client places finished downloads (`COMPLETED_FOLDER`)

Both folders must be readable and writable by Mydia. Final organization still happens during import when Mydia moves or links completed files into the configured library.

## Client Priority

Set the **Priority** field when adding or editing a client on **Admin > Configuration > Clients**; a *lower* number is tried before a higher one, so priority 1 is used before priority 2. The default is 1.

Only clients that support the release's protocol are considered, and Mydia hands the release to a single client. There is no automatic failover: if the selected client rejects the release or is unreachable, the grab fails rather than retrying against the next client. See [How a Title Becomes a File](../explanation/media-pipeline.md#download-client-priority-and-its-one-sharp-edge) for why.

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

- [Indexers](connect-indexer.md) - Configure release searching
- [Environment Variables](../reference/environment-variables.md) - All configuration options
