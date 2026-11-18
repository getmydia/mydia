# Outbound HTTP proxy

Issue: #1437 ("Both Cardigann engines appear to ignore HTTP_PROXY and HTTPS_PROXY").

## Problem

Mydia has no notion of an outbound proxy. Req, Finch and Mint do not read
`HTTP_PROXY`, `HTTPS_PROXY` or `NO_PROXY`, so an operator whose container can only
reach the internet through a proxy gets opaque failures everywhere: the native
Cardigann engine reports `Connection failed: :closed`, the WASM engine reports
`No answer from the tracker`, and nothing reaches the proxy's logs. Cardigann is
only where the reporter noticed it. Every Req call in `lib/` (about 129 call sites
in 49 files) has the same gap.

## Goal

One proxy setting that applies to all outbound internet HTTP made from Elixir,
while LAN services (download clients, Prowlarr, Jellyfin, FlareSolverr) keep being
reached directly, and without weakening the SSRF guarantees of
`Mydia.Plugins.Net.Gate`.

Success: the reporter's compose file (`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` set,
nothing else changed) makes both Cardigann engines, torrent fetches and metadata
relay calls go through the proxy, and a misconfigured proxy produces an error that
names the proxy.

## Non-goals

- SOCKS proxies. Mint supports only HTTP and HTTPS proxies (CONNECT tunnelling for
  `https://` targets, absolute-form requests for `http://` targets). That covers
  Mihomo, Squid, Privoxy and similar.
- Rust-side egress: the built-in torrent client (rqbit) and iroh p2p. They have
  their own network settings; the issue asks for indexer traffic to be independent
  of the torrent client's.
- FlareSolverr's own outbound fetches. Mydia reaches FlareSolverr directly as a
  LAN service; what FlareSolverr fetches is FlareSolverr's configuration.
- Per-indexer proxy overrides.

## Configuration

A new `proxy` section in `Mydia.Config.Schema`, defined in
`lib/mydia/config/schema/proxy.ex`, with env parsing in
`lib/mydia/config/env/proxy_env.ex`. It takes part in the normal
yaml -> db -> env overlay.

| Field | Type | Meaning |
| --- | --- | --- |
| `url` | string, optional | `http://[user:pass@]host:port` or `https://[user:pass@]host:port` |
| `bypass` | string, comma-separated | extra hosts that always go direct (curl `NO_PROXY` syntax); a string because DB-overlay rows hold one string |

Mydia-specific env vars: `MYDIA_PROXY_URL`, `MYDIA_PROXY_BYPASS` (comma-separated).

**Fallback to the standard variables.** When the layered config leaves `url`
unset, the effective URL is the first non-empty of `HTTPS_PROXY`, `https_proxy`,
`HTTP_PROXY`, `http_proxy`. When it leaves `bypass` unset, the effective list comes
from `NO_PROXY`, then `no_proxy`. One proxy serves both `http://` and `https://`
targets, as in Sonarr and Radarr; separate per-scheme proxies are not supported.
The fallback is resolved by the config loader, not read ad hoc at request time.

**Validation.** A `url` whose scheme is not `http` or `https`, or that lacks a host
or port, fails config validation with a named error. It never silently degrades to
a direct connection. The schema and the router share one parser
(`Mydia.Net.Proxy.parse_url/1`), which checks the port on the raw authority
because `URI.parse/1` turns a bad port into nil or the scheme default. An unusable
standard variable (`HTTPS_PROXY` etc.) is not Mydia's setting, so it cannot fail
validation: it is ignored with a logged warning, requests go direct, and
`Mydia.Net.Proxy.config_error/0` carries the reason to the Settings page.
Credentials in the URL become a
`proxy-authorization: Basic ...` header and are masked wherever the config is
displayed or logged.

## Routing rules

For each request, the effective host is `connect_options[:hostname]` when the
caller set it (the Gate does, see below) and otherwise `request.url.host`. The
request goes **direct** when any of these hold:

1. No proxy URL is configured.
2. The host is `localhost`, or a single-label name with no dot (Docker service
   names such as `jellyfin`, `qbittorrent`, `prowlarr`).
3. The host is an IP literal that `Mydia.Plugins.Net.Gate.public_ip?/1` rejects
   (loopback, RFC1918, link-local, CGNAT, ULA, multicast, reserved). This is
   checked on `request.url.host` too, even when `:hostname` is set: the Gate pins
   an approved plugin endpoint (which may be on the LAN) to its private IP, and a
   proxy cannot reach it.
4. The host matches a `bypass` entry, with curl `NO_PROXY` semantics:
   - `*` matches everything;
   - `example.com`, `.example.com` and `*.example.com` match the domain and all
     its subdomains;
   - an IP literal matches that address;
   - a CIDR (`10.0.0.0/8`, `fd00::/8`) matches addresses in range when the host is
     an IP literal;
   - matching is case-insensitive and ignores a trailing dot and any port.

Everything else goes through the proxy. Routing never performs DNS lookups.

## Components

### `Mydia.Net.Proxy`

Pure functions plus a cached view of the effective config.

- `parse(url) :: {:ok, t} | {:error, reason}` builds the Mint proxy tuple
  `{scheme, host, port, []}` and the optional `proxy_headers`.
- `route(host, config) :: :direct | {:proxy, connect_opts}` applies the rules above.
- `put_config/1` stores the parsed effective config in `:persistent_term`. It is
  called after the config loads at boot and from the existing config change
  broadcast (`Mydia.Config.Broadcast`), so a DB-overlay edit takes effect without a
  restart. `current/0` reads it.

### `Mydia.Net.ProxyAdapter`

A Req adapter installed once at application start with
`Req.default_options(adapter: &Mydia.Net.ProxyAdapter.run/1)`, unconditionally.
When no proxy is configured it is a pass-through, so config changes never require
reinstalling it. `run/1`:

1. If the request's `connect_options` already contain `:proxy`, it leaves them alone.
2. Otherwise it calls `Proxy.route/2` with the effective host. On
   `{:proxy, opts}` it merges `proxy:` and `proxy_headers:` into `connect_options`.
3. It delegates to `Req.Finch.run/1`, which keeps proxied connections in their own
   Finch pool.

Callers that set their own `adapter:` or `plug:` bypass it. That is intended: tests
use `Req.Test` plugs, and the Cardigann bench (`Mydia.Indexers.Cardigann.Bench.Runner`)
already swaps the adapter through `Req.default_options/1` for the length of a run.
The bench must chain to `ProxyAdapter` instead of `Req.Finch` so a bench run under a
proxy measures the proxied path; it already saves and restores the previous default
options, so restoring returns the proxy adapter.

### SSRF gate (`Mydia.Plugins.Net.Gate`)

No behaviour change. The Gate still parses the URL, applies the host allowlist,
resolves DNS itself, rejects private targets and pins the connection to the
validated IP literal, passing the original hostname as `connect_options[:hostname]`.
Because the adapter routes on that hostname, a proxied Gate request becomes
`CONNECT <validated-ip>:443` to the proxy. Mint's tunnel honours `:hostname` for
SNI and certificate verification (`deps/mint/lib/mint/tunnel_proxy.ex`,
`Mint.Core.Util.hostname/2`), so TLS still validates against the real name. The
proxy never resolves the name, so the validate-then-connect DNS-rebinding window
stays closed. An approved endpoint pinned to a private or loopback IP goes direct
(routing rule 3).

Consequence: WASM engines and plugins still need DNS resolution inside the
container even when a proxy is configured. The moduledoc gains a paragraph stating
this and why.

### Error reporting

Proxy failures become readable errors instead of `:closed` or "No answer from the
tracker":

- a transport failure on a proxied request (refused, timeout, closed) ->
  "connection through proxy <host>:<port> failed: <reason>". Mint reports a
  refused proxy as a plain transport error, indistinguishable from a failure after
  the tunnel opened, so the message does not claim which hop failed;
- a `407` on CONNECT -> "proxy <host>:<port> requires authentication";
- any other non-2xx on CONNECT -> "proxy <host>:<port> refused the tunnel (<status>)".

Mint reports these as `Mint.HTTPError`/`Mint.TransportError` with a
`{:proxy, reason}` reason. A shared `Mydia.Net.Proxy.describe_error/1` maps them and
is used by the native Cardigann engine's error path, the Gate's
`classify_transport_error`, and the Cardigann health check, so the indexer test
button and health status show the proxy message.

### Settings UI

A proxy row on the admin settings page, following the existing service-config
row plus modal pattern (`lib/mydia_web/components/README.md`). It shows the
effective URL with the password masked, the bypass list, and where each value came
from (yaml, db, `MYDIA_PROXY_*`, or the standard variables). Editing writes the DB
overlay like other settings.

A **Test proxy** button sends one request through the proxy to the configured
metadata relay's `/health` endpoint, forcing the proxy route regardless of bypass
rules, and reports the status code and latency or the `describe_error/1` message.
When no proxy is configured the button is disabled.

## Testing

Tests pass config explicitly and never mutate the process environment
(`test/README.md`).

**Unit (`Mydia.Net.Proxy`)**

- URL parsing: http and https proxies, credentials to `proxy_headers`, missing port,
  unsupported scheme (`socks5://`), garbage.
- Effective config precedence: layered `url` over `HTTPS_PROXY` over `https_proxy`
  over `HTTP_PROXY` over `http_proxy`; `bypass` over `NO_PROXY` over `no_proxy`.
- Bypass matching: exact host, bare and leading-dot domains, subdomain, case and
  trailing dot, IPv4 and IPv6 literals, CIDRs, `*`, port stripping.
- Automatic direct routing for `localhost`, single-label names and private IP
  literals.
- `connect_options[:hostname]` takes precedence over a pinned IP in the URL.

**Integration**

An in-test CONNECT proxy (a small `:gen_tcp` listener that records requests,
tunnels CONNECT, and can be told to answer 407) in front of a Bypass HTTPS target:

- a plain Req call, a native Cardigann search request and a Gate request each reach
  the target through the proxy, and the proxy log shows the expected CONNECT line
  (for the Gate, the validated IP);
- a bypassed host and a single-label host never reach the proxy;
- a caller-set `connect_options[:proxy]` is respected;
- 407 and a refused proxy port produce the `describe_error/1` messages through both
  Cardigann engines;
- with a proxy configured, the Gate still rejects a hostname that resolves to a
  private address before any connection is made;
- a config broadcast that changes the proxy takes effect on the next request.

**LiveView**

- The proxy row renders the masked URL and source, and the test button reports
  success and failure (proxy behind the in-test listener).

## Docs

- `docs/using/reference/environment-variables.md`: `MYDIA_PROXY_URL`,
  `MYDIA_PROXY_BYPASS` and the standard-variable fallback.
- `docs/using/reference/configuration.md`: the `proxy` section, routing rules, the
  HTTP/HTTPS-only limit, and that the built-in torrent client and remote access are
  not proxied.
- `Mydia.Plugins.Net.Gate` moduledoc: proxying and the local-DNS requirement.
