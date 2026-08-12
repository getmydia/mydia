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
| Stalled Timeout | Minutes without progress before a download is flagged as stalled | `60` |

## Stalled Downloads

Mydia watches byte progress on every active download and acts in two stages.

**Stage 1: flagged as stalled.** A download that makes no byte progress for the client's **Stalled Timeout** (default 60 minutes) is flagged with a yellow "Stalled" badge on the Downloads screen. This is a warning, not a verdict. The download keeps its place in the queue, and if bytes start moving again the flag clears itself.

**Stage 2: given up on.** If the download stays stalled for three times the timeout after that (180 minutes on the default, so **4 hours without progress in total**), Mydia gives up on the release. It:

- removes the torrent from your download client
- blocklists that release for **1 day**, so the replacement search does not immediately grab the same dead copy back
- deletes the download from the queue
- queues a fresh search straight away

The blocklist is deliberately short. A torrent with no seeds today may have seeds tomorrow, so a stall earns a cooldown rather than the near-permanent block a corrupt release gets. You will find the give-up recorded in the activity feed and on the media item's history.

While a download is in stage 1, the row tells you exactly when stage 2 will fire and offers two buttons: **Remove and find another** does it immediately, and **Keep waiting** resets the clock and buys another full window.

### Restarts, outages, and paused torrents do not count

Stall time only accrues while Mydia is actually watching a download run. If it goes unobserved for more than 6 minutes, for any reason, the clock resets instead of accruing.

That covers a Mydia restart, a download client that goes unreachable, and a torrent you paused or that sat queued behind others. It is why a torrent can look frozen at the same byte count for a day and never be touched: Mydia only counts the stretches where it watched the download fail to progress, not wall-clock time.

### When Mydia stops giving up

Giving up is capped per media item. After a few automatic rejections for the same movie or episode (3 by default, configurable via `auto_reject_limit`), Mydia stops rejecting and leaves further stalled downloads alone.

The reasoning: if Mydia has already thrown away several releases for one item, the likeliest explanation is that the detection is wrong rather than that every release is bad. Leaving the download alone gives it the chance to finish.

### Debrid clients

Debrid clients default to a 1440-minute (24 hour) timeout instead of 60, because an uncached release legitimately sits waiting on the provider for hours. That makes the give-up deadline **4 days** of no progress. This is intentional: a debrid wait is not a stall.
