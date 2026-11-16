# Configuration Reference

Mydia supports multiple configuration sources with a defined precedence order.

## Configuration Sources

### 1. Environment Variables (Highest Priority)

Environment variables override all other configuration sources. See [Environment Variables](environment-variables.md) for complete reference.

### 2. Database Settings

Settings configured through the Admin UI are stored in the database and persist across restarts.

Access via **Admin > System > Settings**.

### 3. YAML Configuration File

Place a `config.yml` file in the `/config` directory:

```yaml
# /config/config.yml
movies_path: /media/movies
tv_path: /media/tv
```

### 4. Schema Defaults (Lowest Priority)

Built-in defaults are used when no other configuration is specified.

## Configuration Precedence

Configuration is loaded in this order (highest to lowest priority):

1. **Environment Variables** - Override everything
2. **Database Settings** - Configured via Admin UI
3. **YAML File** - From `config/config.yml`
4. **Schema Defaults** - Built-in defaults

Configuration is validated when the application starts, before the rest of the
system comes up, so an invalid value is reported at boot rather than at first
use.

Most settings take effect as soon as they are saved. Settings that are read once
during startup, notably the HTTP port and bind address, are stored immediately
but do not move the running listener until the application restarts. The database
adapter is fixed at build time and cannot change at runtime at all; see
[PostgreSQL Support](../how-to/postgresql.md).

For why the layers exist and what the database layer buys you, see
[Why Configuration Is Layered](../explanation/configuration-model.md).

## Outbound proxy

If your server can only reach the internet through an HTTP or HTTPS proxy, configure it once and Mydia sends its outbound internet requests through it: indexer searches (both Cardigann engines), metadata, torrent file fetches and update checks.

```yaml
# /config/config.yml
proxy:
  url: http://proxy.lan:3128
  bypass: nas.local,.example.com,192.168.50.0/24
```

`url` may carry credentials (`http://user:pass@proxy.lan:3128`); they are masked wherever Mydia shows the setting. The port defaults to 80 for `http://` and 443 for `https://`. SOCKS proxies are not supported. A Mydia proxy setting that cannot be used, such as a SOCKS URL or a port outside 1 to 65535, is rejected with an error naming the setting. An unusable `HTTPS_PROXY` or `HTTP_PROXY` is ignored instead: Mydia logs a warning, connects directly, and shows the problem in the **Proxy** section of the settings page.

The same settings are available as `MYDIA_PROXY_URL` and `MYDIA_PROXY_BYPASS` (see [Environment Variables](environment-variables.md#outbound-proxy)) and under **Admin > System > Settings**, in the **Proxy** section. That section shows the current value and where it came from, and its **Test proxy** button checks that the metadata relay is reachable through the proxy. When no Mydia setting is present, the standard `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` variables are used.

### Which requests use the proxy

These always connect directly:

- `localhost` and single-word names with no dot, such as the Docker service name `qbittorrent`
- private, loopback, link-local, carrier-grade NAT and unique-local IP addresses
- anything matching `bypass`

Everything else goes through the proxy. A name that contains a dot, such as `nas.local`, goes through the proxy unless you list it in `bypass`.

`bypass` is a comma-separated list. Each entry is one of:

| Entry | Matches |
|-------|---------|
| `tracker.example.com` | that host and its subdomains |
| `.example.com` or `*.example.com` | `example.com` and its subdomains |
| `192.168.50.7` | that address |
| `192.168.50.0/24` | every address in the range |
| `*` | everything, which turns the proxy off |

### What is not proxied

- The built-in torrent client. It has its own network settings.
- Remote access (P2P).
- Requests that FlareSolverr makes itself. Mydia reaches FlareSolverr directly, and what it fetches is configured in FlareSolverr.

WASM (Prowlarr-based) indexers still need DNS to work inside the Mydia container. Mydia resolves and checks the address itself before connecting, then asks the proxy to open a tunnel to that address. A plugin endpoint you approved that resolves to a private or loopback address, such as a media server on your LAN, connects directly.

## Plugin instances

For installing, approving and updating plugins, see
[Install and manage plugins](../how-to/plugins.md). Plugin instances can be
declared in YAML. Keys under `settings` are the
plugin's own settings. `name` identifies the instance across restarts.

```yaml
plugin_instances:
  - plugin: plex
    name: Living room
    enabled: true
    settings:
      url: http://192.168.1.20:32400
      token: your-plex-token
      sync_watched: "on"
```

Declared instances overlay the ones created in the UI and are shown read-only.
If one disappears from the config it becomes a disabled instance you manage in
the UI, so its linked accounts are kept. `media_servers:` entries with
`type: plex` are translated into `plugin_instances` entries and are deprecated.

The same instances can be declared with `PLUGIN_<SLUG>_<N>_<KEY>` environment
variables; see [Media Servers](environment-variables.md#media-servers).

Settings for installed plugins can be declared under `plugin_settings`:

```yaml
plugin_settings:
  - slug: assistant-openai
    settings:
      base_url: http://ollama.lan:11434/v1
      model: llama3.1
```

Environment variables override these; see
[Plugins](environment-variables.md#plugins). `plugin_installs:` is no longer
read.

Signed plugin sources can be declared under `plugin_sources`:

```yaml
plugin_sources:
  - url: https://example.com/index.json
    public_key: RW...
```

`PLUGINS_SOURCE_<N>_URL` and `PLUGINS_SOURCE_<N>_PUBLIC_KEY` environment
variables add to these sources, they do not replace them. See
[Plugin sources](environment-variables.md#plugin-sources).

Three plugin limits live in the `plugins:` block:

```yaml
plugins:
  setup_timeout_ms: 30000       # time allowed for one setup wizard step
  store_max_keys: 1000000       # stored entries per instance
  store_max_bytes: 268435456    # stored bytes per instance (256 MiB)
```

`plugins.index_url` can point at a staging official index, but then
`plugins.index_public_key` is required. `plugins.extra_source_urls` is no longer
read and logs a warning; declare sources with `plugin_sources` instead.
