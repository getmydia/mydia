# Download Clients Reference

Complete reference of the download client types Mydia supports.

Mydia supports the following client types. All are configurable via the Admin UI, environment variables, or a YAML config file.

## Torrent Clients

| Client | Type value | Protocol | Features |
|--------|------------|----------|----------|
| qBittorrent | `qbittorrent` | HTTP API | Categories, labels, seeding |
| Transmission | `transmission` | RPC | Categories, seeding |
| rqbit | `rqbit` | HTTP API | Lightweight torrent client, seeding |
| rTorrent | `rtorrent` | XML-RPC | Categories, seeding |
| Blackhole | `blackhole` | Watch directory | Drops `.torrent` files for an external client to pick up |

## Usenet Clients

| Client | Type value | Protocol | Features |
|--------|------------|----------|----------|
| SABnzbd | `sabnzbd` | HTTP API | Categories, priorities |
| NZBGet | `nzbget` | JSON-RPC | Categories, priorities |

## Debrid Services

| Client | Type value | Providers |
|--------|------------|-----------|
| Debrid | `debrid` | `real_debrid`, `all_debrid`, `premiumize`, `tor_box` |

## Configuration Fields

These fields appear when adding or editing a client in the Admin UI. Not every field applies to every client type; see the per-client notes in [Connecting a Download Client](../how-to/connect-download-client.md) for which ones a given type uses.

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
