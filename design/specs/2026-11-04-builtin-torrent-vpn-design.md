# Built-in torrent client with optional VPN

Status: approved design, 2026-11-04. The built-in client is meant to ship. The
VPN is an experimental proof of concept: if the gluetun patch proves too costly
to carry, it is dropped and the built-in client stands on its own.

## Goal

A fresh install downloads torrents with no external client. A user who wants
torrent traffic behind a VPN picks a provider and enters the same credentials
the provider's own app asks for. Only torrent traffic goes through the tunnel;
Mydia's own traffic (indexers, metadata relay, Plex/Jellyfin/Stash, p2p remote
access) keeps its normal route. Nothing fails silently.

## Where Mydia stands

- `Mydia.Downloads.Client.Rqbit` drives a user-run `rqbit server` over its HTTP
  API, addressing torrents by info hash. It is tested
  (`test/mydia/downloads/client/rqbit_test.exs`) and covered by the seeding
  guard and observed seed time (`lib/mydia/downloads/README.md`).
- Clients are configured with `DOWNLOAD_CLIENT_<N>_*` env vars
  (`docs/using/reference/environment-variables.md`).
- The image is Alpine. `docker-entrypoint-prod.sh` runs as root, adjusts
  `PUID`/`PGID`, then drops to the `mydia` user with `su-exec`.
- No VPN code exists.

## Decisions and why

- **Engine as a supervised `rqbit` child process, not a librqbit NIF.** It
  reuses the existing adapter unchanged, keeps engine crashes out of the BEAM,
  and upgrades by bumping a binary.
- **Hard kill switch when the VPN is on.** No packet from the engine leaves
  outside the tunnel: peer TCP, uTP, DHT, UDP and HTTP trackers, DNS. A leaked
  IP makes the feature worse than not having it.
- **`NET_ADMIN` only, never `SYS_ADMIN`.** A network namespace inside Docker
  needs `CAP_SYS_ADMIN`, so isolation is by group: the engine runs under a
  dedicated `mydia-torrent` group, and routing and firewall rules match that
  group's fwmark.
- **SOCKS is not enough.** rqbit's SOCKS5 support covers outgoing peer TCP and
  HTTP trackers only; DHT, UDP trackers and listeners go direct. librqbit has
  no pluggable socket layer.
- **Provider support comes from gluetun, patched.** Gluetun has 30+ providers,
  server selection, username/password login for OpenVPN providers (including
  PIA), and port forwarding for PIA and ProtonVPN. Unpatched, it takes over the
  whole container's routing, firewall and DNS, which would put all of Mydia
  behind the VPN and degrade iroh's direct connections. A patch adds a split
  mode keyed on the torrent group. Rejected alternatives: our own WireGuard
  code (users must download a `.conf`, provider code is ours to maintain),
  stock gluetun in or beside the image (no split tunnel), reusing gluetun's
  `internal/provider` from our own binary (no key generation for any WireGuard
  provider, glue against internal packages), haugene's
  docker-transmission-openvpn configs (OpenVPN only, four providers).
- **Env vars, no DB overlay.** Matches how clients are configured. Credentials
  stay out of the database.

## Configuration

| Variable | Meaning | Default |
| --- | --- | --- |
| `MYDIA_TORRENT_ENABLED` | `true` forces the built-in client on, `false` off. Unset: on when no torrent-type client (`qbittorrent`, `transmission`, `rqbit`, `rtorrent`) is configured. | unset |
| `MYDIA_TORRENT_DOWNLOAD_PATH` | Where the engine writes. | `/data/downloads` |
| `MYDIA_TORRENT_PORT` | Listen port without a forwarded port. | `51413` |
| `MYDIA_VPN_SERVICE_PROVIDER` | Turns the VPN on. Any gluetun provider name. | unset |
| `MYDIA_VPN_*` | Every other gluetun variable, prefix stripped before it reaches gluetun (e.g. `MYDIA_VPN_OPENVPN_USER`, `MYDIA_VPN_SERVER_REGIONS`, `MYDIA_VPN_VPN_PORT_FORWARDING`). Gluetun's documentation applies as written. | |

Mydia sets the gluetun variables it owns itself (control server address, split
mode gid, DNS behaviour) and refuses a user value for them with a startup
error naming the variable.

When the VPN is on, the container needs `cap_add: [NET_ADMIN]` and
`devices: [/dev/net/tun]`. Without the VPN it needs neither.

## Components

`Mydia.Downloads.BuiltIn`, a supervisor started only when the built-in client
is enabled:

- **`Config`**: reads and validates the env vars above into a struct. Pure.
- **`Engine`**: runs `rqbit server` as a port-supervised child on
  `127.0.0.1:<api port>` with generated basic-auth credentials, session state
  in `/config/rqbit`, `--listen-port` from `Status`. When the VPN is on it
  runs as group `mydia-torrent` with no capabilities and `--bind-device` set
  to gluetun's tunnel interface. The group switch comes from the binary
  itself: the image installs `rqbit` setgid `mydia-torrent`, because the BEAM
  runs with no capabilities and granting it `CAP_SETGID` would let it take
  any group. It registers as a
  synthetic download client of type `rqbit` with `managed: true`; grab,
  monitor, import, the seeding guard and removal all go through the existing
  `Rqbit` adapter.
- **`Vpn`**: started only when the VPN is configured. Gluetun itself is
  started by the entrypoint as root (see Data flow), because its own traffic
  (provider API calls, DNS upstream, public IP lookup) must be tunneled and
  gluetun joins the split group itself (`Setgid(SPLIT_TUNNEL_GID)`); a process the BEAM spawned would carry
  the BEAM's uid and need capabilities the BEAM should not hold. `Vpn` reads
  the entrypoint's preflight file `/config/gluetun/preflight` and the
  generated control-server API key `/config/gluetun/apikey`, and polls the
  control server on `127.0.0.1:8000` (`X-API-Key` header) every 10 seconds:
  `GET /v1/vpn/status` (`{"status":"running"}`), `GET /v1/publicip/ip`
  (`{"public_ip":...}`), `GET /v1/portforward` (`{"port":N}`). Gluetun's log
  goes to `/config/gluetun/gluetun.log`; the last error line is shown with
  `:vpn_down`.
- **`LeakCheck`**: once per tunnel start, requests the public IP as the torrent
  group (`torrent-curl`, a copy of `curl` installed setgid `mydia-torrent`)
  and as Mydia (`Req`), using an IP echo endpoint on
  metadata-relay. Equal IPs, or the torrent group reaching the endpoint while
  gluetun reports the tunnel down, is a leak.
- **`Status`**: one struct, broadcast on PubSub:

| Part | States |
| --- | --- |
| engine | `disabled`, `starting`, `running`, `stopped(reason)`, `crashed(reason, restarts)` |
| vpn | `off`, `connecting`, `up(provider, server, public_ip)`, `down(reason)` |
| port | `static(n)`, `forwarded(n, since)`, `failed(reason, last_port)` |

## Data flow

1. Boot: the entrypoint sees `MYDIA_VPN_SERVICE_PROVIDER`, checks for
   `NET_ADMIN` and `/dev/net/tun`, and writes the result to the preflight
   file. If both are present it generates the API key, then starts gluetun as
   root in a restart loop in the background with the prefix-stripped
   variables plus `SPLIT_TUNNEL_GID`, `HTTP_CONTROL_SERVER_ADDRESS` and
   `HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE`. A missing capability or device is
   never a boot failure. It then drops to the `mydia` user as today; the BEAM
   holds no capabilities. Without the variable the entrypoint behaves exactly
   as today.
2. `Vpn` waits for gluetun to report `running`. `LeakCheck` runs.
3. `Engine` starts only after a passed leak check, with the forwarded port if
   gluetun has one, else `MYDIA_TORRENT_PORT`.
4. A changed forwarded port restarts the engine with the new port. The session
   is persisted, so torrents resume.
5. VPN down: `Engine` is stopped. Gluetun's firewall already drops the
   traffic; stopping the engine is the second layer and keeps downloads from
   reading as stalled. VPN back up: leak check, then engine start.

## The gluetun patch

`vendor/gluetun/` holds `VERSION` (a pinned release tag), `patches/*.patch`
and a README describing each patch and how to rebase onto a new release. The
patches add `SPLIT_TUNNEL_GID=<gid>`. When set:

- **Marking**: iptables `mangle OUTPUT` marks packets from sockets owned by
  gid `SPLIT_TUNNEL_GID` only, except packets to the VPN server endpoint,
  which must leave on the physical interface. Gluetun calls
  `Setgid(SPLIT_TUNNEL_GID)` itself at startup, so it and its OpenVPN child
  are in the group and tunneled. uid 0 is not marked: Docker's embedded DNS
  forwarder runs as uid 0 in the container's namespace, and marking it would
  send all of Mydia's name resolution through the VPN. Kernel WireGuard's own
  socket has no owner and is never marked.
- **Routing**: in place of WireGuard's inverted "not fwmark 51820" rule and
  OpenVPN's pushed `redirect-gateway`, an `ip rule` sends only the split mark
  to the VPN table, which holds the default route through the tunnel and an
  `unreachable` default at a higher metric. The main table is untouched.
- **Firewall**: chain policies stay `ACCEPT`. Marked packets leaving on any
  interface but `lo` and the tunnel are dropped. Inbound on the tunnel only
  established traffic and the forwarded port are accepted, so Mydia's web UI
  is never reachable from the VPN side.
- **DNS**: `resolv.conf` is left alone. Gluetun's DNS server listens on
  `127.0.0.1:53` only, and `nat OUTPUT` redirects marked port 53 traffic to
  it; its upstream queries come from gluetun, which is in the group, and are
  tunneled.
- **Health and restarts**: unchanged.

A Go test in the patch series asserts the rules generated in split mode.

Docker gets a `gluetun` stage (`golang:alpine`, apply patches, `go build`); the
runtime stage copies the binary and adds `openvpn`, `iptables`, `ip6tables`,
`iproute2` (Mydia reads the tunnel address with `ip -4 -o addr show` and starts
rqbit with `--listen-ip`) and `curl`, and creates the `mydia-torrent` group with
the setgid `rqbit` and `torrent-curl`. The `rqbit` binary is built from a
pinned version in the existing cargo stage for musl and both architectures.
The IP echo endpoint is added to metadata-relay in the same PR.

## Transparency

Every failure is a typed reason with fix text, shown on the built-in client's
row in Admin, Download Clients (with an "Experimental" badge on the VPN part),
fed into `ClientHealth` so the dashboard warning lights up, returned as the
adapter's `{:error, reason}` so a grab fails with the cause, and logged at
`error` on each transition.

| Reason | Shown as |
| --- | --- |
| `:missing_net_admin` | Add `cap_add: [NET_ADMIN]` to the container |
| `:missing_tun` | Add `devices: [/dev/net/tun]` to the container |
| `{:reserved_variable, name}` | `MYDIA_VPN_<name>` is set by Mydia; remove it |
| `{:vpn_auth_failed, msg}` | Gluetun's message, e.g. wrong credentials |
| `:vpn_down` | Tunnel down, torrents stopped until it returns |
| `:leak_detected` | Leak check failed; torrents will not start |
| `{:port_forward_failed, msg}` | Engine keeps running on the last port; seeding limited to outgoing connections |
| `{:engine_exit, code}` | rqbit exited; restarting, or crashed after 5 tries |

The engine restarts with backoff up to 5 times, then holds `crashed` until the
configuration changes or an admin presses Restart on the row. Gluetun's own
reconnect logic is left in charge of the tunnel.

## Testing

- Unit: `Config` parsing and auto-enable rules, reserved variables, the
  `Status` state machine, port-change restarts, control-server polling against
  Bypass serving recorded gluetun JSON, `Engine` supervision against a fake
  `rqbit` script.
- The existing `Rqbit` adapter tests are unchanged and must stay green.
- LiveView: the built-in row renders each state and reason.
- The patch's Go test for generated rules.
- Docker smoke test, manual for the proof of concept and documented in
  `vendor/gluetun/README.md`: with ProtonVPN credentials, the torrent group's
  public IP is the VPN's and Mydia's is the host's; with the tunnel interface
  deleted, the torrent group reaches nothing; a magnet completes and imports.

## Out of scope

Nix packaging and the NixOS module for the VPN (the built-in engine gets rqbit
from nixpkgs for devenv), editing VPN settings in the UI, offering the patch
upstream, more than one built-in engine.
