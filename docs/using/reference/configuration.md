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

## Common Configuration Tasks

### Changing Library Paths

**Via Environment Variables:**

```bash
MOVIES_PATH=/new/path/movies
TV_PATH=/new/path/tv
```

**Via Admin UI:**

1. Navigate to **Admin > Settings**
2. Update library paths
3. Mydia validates files are accessible before saving

### Configuring Hostname

For proper link generation:

```bash
PHX_HOST=mydia.example.com
URL_SCHEME=https
```

### Enabling Debug Logging

```bash
LOG_LEVEL=debug
```

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

## Configuration Backup

Database settings are included in automatic database backups. Environment variables and YAML files should be backed up separately as part of your infrastructure management.
