# Configuration Reference

Mydia supports multiple configuration sources with a defined precedence order.

## Configuration Sources

### 1. Environment Variables (Highest Priority)

Environment variables override all other configuration sources. See [Environment Variables](environment-variables.md) for complete reference.

### 2. Database Settings

Settings configured through the Admin UI are stored in the database and persist across restarts.

Access via **Admin > Configuration > Settings**.

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
