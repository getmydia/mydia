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
