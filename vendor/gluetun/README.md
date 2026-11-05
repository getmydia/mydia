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
  inserted ahead of Docker's embedded DNS rules. Gluetun's own (uid 0) DNS is
  not redirected, so a plaintext upstream does not loop, but it is still
  tunneled. Over IPv6, marked port 53 traffic is dropped instead.
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
connections can stall.

### Restarts

Mydia runs gluetun in a restart loop while the engine may keep running, in a
network namespace that keeps the previous run's rules. On enable, each rule
that already exists (`iptables -C`) is added again and only then is one copy
removed, so marking and the kill switch never lapse. If enabling fails
partway, nothing is removed: split tunnel traffic fails closed.

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
- Processes in the group must not run as root: DNS from uid 0 is not
  redirected.
- VPN-side port redirection (`VPN_PORT_FORWARDING_LISTENING_PORT`) appends its
  `INPUT` accept after the tunnel `DROP` and does not work.

## Rebasing onto a new release

1. Clone the new tag, `git am vendor/gluetun/patches/*.patch`.
2. Fix conflicts. They land in `cmd/gluetun/main.go`,
   `internal/firewall/enable.go`, `internal/wireguard/run.go`,
   `internal/vpn/run.go` and `internal/dns/`, where upstream changes most.
3. `go build ./... && go test ./internal/splittunnel/ ./internal/firewall/... ./internal/wireguard/...`
4. Re-export with `git format-patch`, bump `VERSION`, run the smoke test below.

## Smoke test

Build the image (`docker build -t mydia:builtin-vpn .`) and run it with
`--cap-add NET_ADMIN --device /dev/net/tun` and a ProtonVPN WireGuard login
(`MYDIA_VPN_SERVICE_PROVIDER=protonvpn`, `MYDIA_VPN_VPN_TYPE=wireguard`,
`MYDIA_VPN_WIREGUARD_PRIVATE_KEY`, `MYDIA_VPN_VPN_PORT_FORWARDING=on`). Then:

1. `docker exec <c> su-exec mydia torrent-curl -s https://relay.mydia.dev/ip`
   prints the VPN address; the same with plain `curl` prints the host's.
2. Admin, Download Clients shows the VPN connected, its public IP, a forwarded
   port, and the engine running.
3. `docker exec <c> ip link del wg0`: `torrent-curl --max-time 5` fails,
   plain `curl` still works, and within 10 seconds the admin page shows the
   VPN down and the engine stopped.
4. Without `--cap-add NET_ADMIN` the admin page shows the `cap_add` message
   and the engine stays stopped.
5. A magnet grabbed from the UI downloads and imports. While rqbit churns
   peers, `docker exec <c> tcpdump -ni eth0 'not host <vpn endpoint>'` shows
   nothing from the engine: no final ACKs, RSTs or ICMP errors for its
   connections.
6. Gluetun's log has no reverse path filtering warning, or the container has
   the `src_valid_mark` sysctl.
