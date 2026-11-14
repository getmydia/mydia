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

## Built-in

Mydia bundles rqbit and runs it for you, so a fresh install can download
torrents with no client to set up. It appears in Admin, Download Clients as a
managed client named after the built-in engine, with a status panel.

### Set it up from the UI

Everything about the built-in client, its VPN included, is set from Admin,
Download Clients. Changes apply without restarting the container.

1. Open Admin, Download Clients and press **Configure** on the Built-in panel.
   When the client is off the panel still shows, with the reason and an
   **Enable** button.
2. On the **Torrent** tab, choose Automatic, On or Off, and set the download
   path and listen port. State path and API port are under Advanced.
3. On the **VPN** tab, turn the VPN on, pick your provider and VPN type, and
   enter your credentials. Add a server country, region, city or hostname if
   you want to choose where you connect, and turn on port forwarding if your
   provider offers it. Lists are comma-separated.
4. Save. The panel shows each step: applying, connecting, leak check, then
   running with the VPN's public IP and forwarded port. If something fails, it
   names the reason and what to fix.

Each field shows where its value comes from: **ENV** when a container
environment variable sets it, **DB** when you saved it in the UI, or Default.
An ENV field is read-only in the UI, and its tooltip names the variable.
Environment variables win over the UI, so you can keep secrets out of the
database by setting them there. Secrets you save (the OpenVPN password and the
WireGuard private key) are never shown again; the form shows "Saved" and a
Replace button.

What the UI cannot do is give the container the permissions the VPN needs
(`NET_ADMIN`, the tun device and a sysctl). When one is missing, the VPN tab
is disabled and shows the exact lines to add to your compose file. Recreate the
container after adding them.

Some providers need files or keys the form cannot take, such as a client
certificate. The form lists the variables to set for those, named
`MYDIA_VPN_<NAME>` (see
[Environment Variables](environment-variables.md#built-in-torrent-client)).

Two changes ask you to confirm first: turning the client off while downloads
are active (the dialog says how many), and turning the VPN off while the client
runs, since torrents would then use this server's real IP. A new download path
applies to new grabs; torrents already running finish where they started.

### How it behaves

- **Auto-enable.** A new install turns it on: the rqbit binary is installed
  (it is in the Docker image) and no download client of any kind is
  configured yet. Once on, it stays on after restarts and after you add
  clients of your own, until you turn it off (in the UI or with
  `MYDIA_TORRENT_ENABLED=false`). An existing install that already has a
  client, Usenet included, keeps it off until you choose On in the UI or set
  `MYDIA_TORRENT_ENABLED=true`.
- **Reserved name.** The client is listed as "Built-in", and no other client
  may use that name. If an existing client already has it (a database row from
  before the name was reserved, or a `DOWNLOAD_CLIENT_<N>_NAME` of `Built-in`),
  the built-in client stays off, even when you turn it on, and logs why;
  rename that client and restart.
- **Download path.** `/data/downloads` by default. Torrent state lives in
  `/config/rqbit`. In the Docker image, files the engine writes belong to group
  `mydia-torrent`, with or without the VPN.
- **Speed limits.** Download and upload limits, in KiB/s, sit under
  Configure, Torrent. Leave a field blank for no limit; the lowest limit is
  16 KiB/s, since the engine moves data in 16 KiB blocks. A change restarts the
  engine within a few seconds, and torrents resume where they were.
- **No web UI.** The engine has no web interface of its own, so the Downloads
  page shows no "Open" button for it. Mydia's Downloads page is where you
  manage its torrents.
- **VPN (experimental).** Mydia runs a patched gluetun that tunnels only the
  built-in client. The engine starts once the VPN is up and a leak check
  passes, and stops when it drops. Changing any VPN setting runs the same
  checks again before the engine resumes. The panel shows the VPN state,
  public IP, forwarded port and the reason for any failure.

### Set it up with environment variables

Every setting has an environment variable that overrides the UI; they are
listed under
[Environment Variables](environment-variables.md#built-in-torrent-client).
Use them when you manage the container from a compose file. The VPN needs
the container permissions shown below either way.

Both examples need `NET_ADMIN`, the tun device and the `src_valid_mark`
sysctl. `init: true` adds an init process that reaps a VPN process left
behind when gluetun restarts.

ProtonVPN with WireGuard and port forwarding:

```yaml
services:
  mydia:
    image: ghcr.io/getmydia/mydia:latest
    init: true
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    environment:
      MYDIA_VPN_SERVICE_PROVIDER: protonvpn
      MYDIA_VPN_VPN_TYPE: wireguard
      MYDIA_VPN_WIREGUARD_PRIVATE_KEY: ${PROTON_WIREGUARD_KEY}
      MYDIA_VPN_VPN_PORT_FORWARDING: "on"
      MYDIA_VPN_SERVER_COUNTRIES: Netherlands
```

Private Internet Access with OpenVPN:

```yaml
services:
  mydia:
    image: ghcr.io/getmydia/mydia:latest
    init: true
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    environment:
      MYDIA_VPN_SERVICE_PROVIDER: pia
      MYDIA_VPN_OPENVPN_USER: ${PIA_USER}
      MYDIA_VPN_OPENVPN_PASSWORD: ${PIA_PASSWORD}
      MYDIA_VPN_SERVER_REGIONS: Netherlands
```

`pia` is gluetun's spelling of `private internet access`, which the
entrypoint could not pass because of the space.

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
| API Key | API key (SABnzbd, debrid, qBittorrent 5.2+). For SABnzbd, use the API Key from Config > General, not the NZB Key: the NZB Key can add downloads but cannot read the queue, so progress and imports never update. | `abc123` |
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
