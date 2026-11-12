# Patched gluetun

Mydia's experimental VPN runs gluetun with one patch series that adds a split
mode, `SPLIT_TUNNEL_GID=<gid>`. Only sockets owned by that group (the
built-in rqbit and `torrent-curl`) are routed through the VPN and
kill-switched. Gluetun joins the group itself at startup, so its own traffic
(provider APIs, the DNS upstream, health checks, the public IP lookup, the
OpenVPN child) is tunneled too. The rest of the container keeps its normal
route, DNS and an unfiltered firewall.

- `VERSION`: the upstream tag the patches apply to.
- `patches/0001-split-tunnel.patch`: the split mode. `internal/splittunnel`
  builds the iptables rules and the policy routing and has the unit tests.

Unset, gluetun behaves exactly as upstream.

## What split mode does

- **Marking.** `mangle OUTPUT` marks packets from sockets owned by the group
  with `0x5154`, except packets to the VPN server's address, protocol and
  port, which leave on the physical interface. Kernel WireGuard's own socket
  has no owner; userspace WireGuard and OpenVPN sockets hit the endpoint
  exemption. The exemption applies to every socket in the group, not only
  the VPN's: a torrent peer at the VPN server's address and port would be
  reached outside the tunnel.
- **Connection mark.** The mark is saved on the connection (`CONNMARK
  --save-mark`) and restored first thing in `mangle OUTPUT`; connections
  arriving on the tunnel get it in `PREROUTING`. Packets the kernel sends
  for a connection after its socket is gone (final ACKs from `TIME_WAIT`,
  RSTs, ICMP errors) have no owner, and would otherwise take the main table
  out of the default interface with the real address and the swarm ports.
- **Routing.** An `ip rule` at priority 99 sends the mark to the VPN table:
  WireGuard's own table (51820), or table `0x5154` for OpenVPN. The table
  holds the tunnel route and an `unreachable` default at metric 2147483647,
  so marked traffic fails closed when the tunnel route disappears. The main
  table is untouched. Priority 99 sits before gluetun's inbound rule (100),
  which would otherwise route marked packets by their container source address
  out of the default interface.
- **Firewall.** Chain policies stay `ACCEPT`. Marked packets may only leave on
  `lo` or the tunnel. Inbound on the tunnel only established traffic and the
  forwarded port are accepted. Marked traffic leaving on the tunnel is
  masqueraded, because a socket picks its source address from the main table
  before its packets are marked.
- **DNS.** `/etc/resolv.conf` is left alone. The DNS server listens on
  `127.0.0.1:53` only. `nat OUTPUT` redirects marked port 53 traffic to it,
  inserted ahead of Docker's embedded DNS rules. Port 53 traffic from uid 0 is
  exempt from the redirect by uid (the redirect would otherwise loop gluetun's
  own plaintext upstream queries back to itself); gluetun's own traffic is
  tunneled because it is in the group, not because it is uid 0. Over IPv6, marked port 53 traffic is dropped
  instead.
- **IPv6.** When `ip6tables` exists, the marking and kill switch rules are
  applied through it as well; the policy rule and unreachable route are added
  for IPv6 when gluetun detects IPv6 support.
- **Health and restarts.** Unchanged.

### Why gluetun joins the group instead of matching uid 0

Other root processes share the container's network namespace. Docker's
embedded DNS forwarder (every lookup on a Compose network) sends its upstream
queries from inside the container's namespace as uid 0. Matching uid 0 would
put all of Mydia's name resolution through the VPN, and break it whenever the
VPN is down.

### OpenVPN

OpenVPN keeps applying its pushed `redirect-gateway`. On every
"Initialization Sequence Completed", gluetun moves the routes it added to the
main table (`0.0.0.0/1`, `128.0.0.0/1`, and the IPv6 ones) into the split
table, keeping their gateway. `route-noexec` is not used because PIA port
forwarding finds the VPN gateway from those routes. From OpenVPN adding the
routes until gluetun processes the tunnel-up event and moves them, the whole
container routes through the tunnel: nothing leaks, but Mydia's own
connections can stall. If moving them fails, gluetun restarts the VPN run
rather than leave the routes in the main table: stopping OpenVPN removes the
tun interface, and the kernel drops every route through it.

### Restarts

Mydia runs gluetun in a restart loop while the engine may keep running, in a
network namespace that keeps the previous run's rules. On enable, each base
rule (marking, kill switch, DNS) that already exists (`iptables -C`) is added
again and only then is one copy removed, so marking and the kill switch never
lapse. The tunnel rules (the `PREROUTING` marks, the tunnel `INPUT` and
`OUTPUT` rules, `MASQUERADE` and the endpoint `RETURN`) are handled the same
way on the first VPN connection of a run, when gluetun has no rules of its own
to diff against; later reconnects in the same run only add what changed and
then remove what the new connection no longer needs. If enabling fails
partway, nothing is removed: split tunnel traffic fails closed.

A restarted gluetun only knows the rules it is about to add. Tunnel rules of
the previous run that the new connection does not share stay in place: in
practice the endpoint `RETURN` of a server the previous run used, or tunnel
rules for an interface name that changed. A stale `RETURN` exempts traffic to
that old server's address and port from the tunnel. Recreating the container
clears them.

## Requirements and limits

- **Reverse path filtering.** Replies to masqueraded connections arrive on
  the tunnel addressed to the container's own address. On a host with strict
  `rp_filter=1` (the containers inherit it) they are dropped unless
  `net.ipv4.conf.all.src_valid_mark=1`. Gluetun tries to set it and logs a
  warning naming the sysctl when it cannot; Docker mounts `/proc/sys`
  read-only, so the fix is `sysctls: [net.ipv4.conf.all.src_valid_mark=1]` on
  the container. Loose (`2`) or disabled (`0`) filtering needs nothing.
- **Inbound UDP needs a bound socket.** A UDP socket bound to `0.0.0.0`
  answers an inbound datagram from the container's eth0 address, which
  MASQUERADE then rewrites, port included, so the reply leaves the tunnel
  from a different port than the one the peer contacted. The client must
  bind its sockets to the tunnel address (Mydia starts rqbit with
  `--listen-ip <tunnel address>`) for inbound UDP to reply from the right
  port.
- `SPLIT_TUNNEL_GID=0` is rejected: it would match every root process.
- Without `ip6tables`, IPv6 traffic from the group is neither marked nor
  kill-switched. Gluetun logs an error when the container has an IPv6
  default route in that case.
- `FIREWALL_INPUT_PORTS` and `FIREWALL_OUTBOUND_SUBNETS` are ignored, with a
  warning.
- Gluetun's HTTP proxy and Shadowsocks server would send their replies into
  the tunnel; do not enable them. The health server and the control server
  must stay on loopback, as they are by default and as Mydia sets them.
- Other processes in the group that run as root get no DNS redirect, because
  the redirect skips uid 0. Run them as an unprivileged user, as rqbit and
  `torrent-curl` are.
- VPN-side port redirection (`VPN_PORT_FORWARDING_LISTENING_PORT`) appends its
  `INPUT` accept after the tunnel `DROP` and does not work.

### Known limits not addressed

- **No PID 1 reaping.** Mydia's entrypoint `exec`s the application, which
  does not reap orphans. An OpenVPN child left behind when gluetun dies
  becomes a zombie. Run the container with `init: true` (the compose examples
  in the download client docs do) so an init process reaps it.
- **The image is referenced by tag, not digest.** Upstream gluetun and the
  Mydia image are not pinned by digest.
- **The engine is reported running before its API listens.** Mydia marks
  rqbit running once the process starts; requests in the first moments can
  fail with a connection error until its HTTP API is up.

## Rebasing onto a new release

1. Clone the new tag, `git am vendor/gluetun/patches/*.patch`.
2. Fix conflicts. They land in `cmd/gluetun/main.go`,
   `internal/firewall/enable.go`, `internal/wireguard/run.go`,
   `internal/vpn/run.go` and `internal/dns/`, where upstream changes most.
3. `go build ./... && go test ./internal/splittunnel/ ./internal/firewall/... ./internal/wireguard/...`
4. Re-export with `git format-patch`, bump `VERSION`, run the smoke test below.

## How Mydia drives gluetun

Gluetun is configured from a file, not from its settings API. Mydia writes
`/config/gluetun/settings/settings.env`; the root loop in
`docker/vpn-preflight.sh` polls it every 2 seconds and (re)starts gluetun with
the allowlisted keys, then the operator's `MYDIA_VPN_*` env, then Mydia's own
values. The full flow, the `loop-status` file and the error reasons are in
`lib/mydia/downloads/README.md`, "The VPN settings file and the root loop".
What matters when changing gluetun or the script:

- **Allowlist.** `VPN_SERVICE_PROVIDER VPN_TYPE OPENVPN_USER OPENVPN_PASSWORD
  WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES SERVER_COUNTRIES SERVER_REGIONS
  SERVER_CITIES SERVER_HOSTNAMES VPN_PORT_FORWARDING`. `VPN_ENABLED` is read by
  the loop and never passed to gluetun. Any other key is dropped and named in
  `loop-status`; lines that are not `KEY=value` are counted as `invalid=<n>`
  and never echoed.
- **Idle by default.** With no VPN env and `VPN_ENABLED` absent or not `true`,
  the loop runs but gluetun does not.
- **Control server.** Gluetun ignores a route list in the default role, so the
  script writes `/run/mydia-vpn/auth.toml` with one apikey role allowed
  `GET /v1/vpn/status`, `GET /v1/publicip/ip` and `GET /v1/portforward`, and
  sets the default role to `{}`. `HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH`
  points at that file. The key Mydia reads from `/config/gluetun/apikey`
  cannot call `PUT /v1/vpn/settings`, which accepts OpenVPN options that run as
  root.
- **Root never opens a path under /config.** Mydia owns `/config` and could
  swap `/config/gluetun` for a symlink at any time. Every read and write there
  in the script runs as mydia through `su-exec`: the settings file is copied
  (5 second timeout, 64 KiB cap) into a snapshot in `/run/mydia-vpn` (root,
  mode 700), and root parses only the snapshot. `auth.toml` lives there too.
  Keep any new file access to that rule.
- **Bump together.** `Mydia.Downloads.BuiltIn.VpnProviders` is built from the
  gluetun release in `VERSION`; refresh it (including `extra_env`) when the
  version changes.

## Smoke test

Build the image (`docker build -t mydia:builtin-vpn .`) and run it with
`--cap-add NET_ADMIN --device /dev/net/tun
--sysctl net.ipv4.conf.all.src_valid_mark=1` and **no** `MYDIA_VPN_*`
variables. Then:

1. **Idle boot.** `docker exec <c> pgrep gluetun` finds nothing: with no VPN
   configured the loop is running and gluetun is not. Admin, Download Clients
   shows the built-in client running without a VPN, and the VPN tab offers the
   form (no setup card).
2. **Enable from the UI.** On the VPN tab choose ProtonVPN, WireGuard, paste
   a private key, turn on port forwarding and save. The panel goes through
   applying, connecting and leak check, then shows the VPN's public IP, a
   forwarded port and the engine running.
3. **Split IPs.** `docker exec <c> su-exec mydia torrent-curl -s
   https://relay.mydia.dev/ip` prints the VPN address; the same with plain
   `curl` prints the host's.
4. **Change the server.** Set the server country to another country and save.
   The engine stops, gluetun restarts, the panel shows a new public IP, and the
   engine resumes with its torrents still in the session.
5. **Control server lockdown.** From inside the container, with the key Mydia
   uses:

   ```sh
   key=$(cat /config/gluetun/apikey)
   curl -s -o /dev/null -w '%{http_code}\n' -X PUT -H "X-API-Key: $key" \
     http://127.0.0.1:8000/v1/vpn/settings   # 401
   for r in vpn/status publicip/ip portforward; do
     curl -s -o /dev/null -w "$r %{http_code}\n" -H "X-API-Key: $key" \
       http://127.0.0.1:8000/v1/$r            # 200 each
   done
   ```

   The `PUT` returns 401 and the three `GET` routes return 200.
6. **Drop.** `docker exec <c> ip link del wg0`: `torrent-curl --max-time 5`
   fails, plain `curl` still works, and within 10 seconds the admin page shows
   the VPN down and the engine stopped.
7. **Env wins.** Recreate the container with `MYDIA_VPN_SERVER_COUNTRIES` set:
   the field shows the ENV badge and is read-only, and the value is not in
   `/config/gluetun/settings/settings.env`.
8. **Turn it off.** Turn the VPN off in the UI and confirm the dialog: gluetun
   stops (`pgrep gluetun` finds nothing) and the engine restarts without the
   VPN.
9. **No capabilities.** Without `--cap-add NET_ADMIN` the VPN tab is disabled
   and shows the compose lines; the engine stays stopped if the VPN was
   configured.
10. A magnet grabbed from the UI downloads and imports. While rqbit churns
    peers, `docker exec <c> tcpdump -ni eth0 'not host <vpn endpoint>'` shows
    nothing from the engine: no final ACKs, RSTs or ICMP errors for its
    connections.
11. Gluetun's log has no reverse path filtering warning, or the container has
    the `src_valid_mark` sysctl.

On `docker stop`, gluetun gets SIGKILL with no teardown. That is harmless: the
rules, routes and tunnel live in the container's network namespace, which dies
with the container.

The smoke test needs real VPN credentials and has not been run against the
image yet. Record any deviation here after the first run. `docker/vpn-preflight.sh`
records `src_valid_mark=ok|missing` in `/config/gluetun/preflight`; Mydia does
not read that key yet, so check 11 is done by hand.
