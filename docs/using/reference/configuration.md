# Configuration Reference

Mydia supports multiple configuration sources with a defined precedence order.

## Configuration Sources

### 1. Environment Variables (Highest Priority)

Environment variables override all other configuration sources. See [Environment Variables](environment-variables.md) for complete reference.

### 2. Database Settings

Settings configured through the Admin UI are stored in the database and persist across restarts.

Access via **Admin > Settings**.

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

<!-- MOVES TO explanation/configuration-model.md IN TASK 11

## Configuration Validation

Mydia validates configuration at startup:

- Required variables must be set
- Paths must be accessible
- Connections are tested when possible

Invalid configuration is logged with helpful error messages.

## Runtime Configuration Changes

Some settings require a restart:

| Setting | Requires Restart |
|---------|------------------|
| Library paths | No |
| Hostname/Port | Yes |
| Authentication settings | Yes |
| Feature flags | Yes |
| Log level | No |

-->
