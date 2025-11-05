# Hooks System - Configuration Guide

## Overview

The Mydia hooks system uses a configurable directory for user-defined hooks. The hooks directory path is **relative to the database directory**, making it easy to develop locally and deploy with Docker.

## How It Works

- **Relative paths**: Resolved relative to the database directory
  - Development: `database.path: "mydia_dev.db"` + `hooks.directory: "hooks"` = `./hooks`
  - Production: `database.path: "/config/mydia.db"` + `hooks.directory: "hooks"` = `/data/hooks`

- **Absolute paths**: Used as-is (for advanced configurations)

This approach means:
- ✅ No path changes needed between dev and production
- ✅ Hooks live alongside your data (easy to backup together)
- ✅ Docker manages the absolute paths via volume mounts

## Configuration

### 1. config.yaml

The hooks directory is configurable via `config.yaml`:

```yaml
database:
  path: "/config/mydia.db"  # Or "mydia_dev.db" in development

hooks:
  # Enable or disable the hooks system
  enabled: true

  # Directory where hook scripts are located (relative to database directory)
  directory: "hooks"

  # Default timeout for hook execution in milliseconds
  default_timeout_ms: 5000

  # Maximum allowed timeout for hooks in milliseconds
  max_timeout_ms: 30000
```

### 2. Docker Compose

In Docker, mount a single data volume. Hooks will be stored alongside the database:

```yaml
version: '3.8'

services:
  mydia:
    image: mydia:latest
    container_name: mydia
    ports:
      - "4000:4000"
    volumes:
      # Configuration file
      - ./config.yaml:/config/config.yaml:ro

      # Data directory (includes database and hooks)
      - ./data:/data

      # Media directories
      - ./media/movies:/media/movies
      - ./media/tv:/media/tv
    environment:
      - LOAD_RUNTIME_CONFIG=true
```

With `database.path: "/config/mydia.db"` and `hooks.directory: "hooks"`, hooks will be located at `/data/hooks` inside the container.

## Directory Structure

### Development (Local)

```
./
├── mydia_dev.db           # Database (default development location)
├── hooks/                 # Hooks directory (relative to database)
│   ├── after_media_added/
│   │   └── 01_example_anime_settings.lua
│   ├── on_download_completed/
│   │   └── 01_post_process.lua
│   └── before_automatic_search/
│       └── 01_search_tweaks.lua
├── lib/
├── mix.exs
└── ...
```

### Production (Docker)

```
./
├── config.yaml           # Configuration
├── data/                 # Data directory (mounted volume)
│   ├── mydia.db          # Database
│   └── hooks/            # Hooks directory (relative to database)
│       ├── after_media_added/
│       │   └── 01_my_hook.lua
│       └── on_download_completed/
│           └── 01_post_process.lua
└── media/
    ├── movies/
    └── tv/
```

## Creating Hooks

### Development

```bash
# Create hook directory
mkdir -p hooks/after_media_added

# Create hook file
cat > hooks/after_media_added/01_my_hook.lua <<'EOF'
function execute(event_data)
  local media = event_data.data.media_item

  log.info("Processing: " .. media.title)

  return {
    modified = false,
    message = "Hook executed successfully"
  }
end

return execute(event)
EOF

# Hooks are loaded on application startup
./dev mix phx.server
```

### Production (Docker)

#### Option 1: Create on Host Machine

```bash
# Create hook directory in data volume
mkdir -p ./data/hooks/after_media_added

# Create hook file
cat > ./data/hooks/after_media_added/01_my_hook.lua <<'EOF'
function execute(event_data)
  local media = event_data.data.media_item
  log.info("Processing: " .. media.title)
  return {modified = false, message = "Hook executed"}
end
return execute(event)
EOF

# Restart container to reload hooks
docker-compose restart mydia
```

#### Option 2: Create Inside Container

```bash
# Create directory inside container
docker exec mydia mkdir -p /data/hooks/after_media_added

# Create hook file inside container
docker exec mydia sh -c 'cat > /data/hooks/after_media_added/01_my_hook.lua <<EOF
function execute(event_data)
  local media = event_data.data.media_item
  log.info("Processing: " .. media.title)
  return {modified = false, message = "Hook executed"}
end
return execute(event)
EOF'

# Restart container to reload hooks
docker-compose restart mydia
```

## Hook Priority

Hooks are executed in alphabetical order based on filename. Use numeric prefixes to control execution order:

- `01_first_hook.lua` - Executes first
- `02_second_hook.lua` - Executes second
- `99_last_hook.lua` - Executes last

## Disabling Hooks

To disable the hooks system entirely, set `enabled: false` in config.yaml:

```yaml
hooks:
  enabled: false
  directory: "/config/hooks"
```

Or set an empty hooks directory to prevent any hooks from loading while keeping the system enabled.

## Troubleshooting

### Hooks Not Loading

1. Check hooks are enabled in config.yaml
2. Verify the directory path matches the volume mount
3. Check container logs: `docker logs mydia | grep -i hooks`
4. Ensure hook files have `.lua` extension
5. Verify file permissions allow reading by container user

### Hook Execution Errors

1. Check syntax errors in Lua scripts
2. Verify hook returns valid result format
3. Check timeout settings if hooks take too long
4. Review container logs for detailed error messages

### Permission Issues

If hooks can't be read due to permissions:

```bash
# Fix permissions on host
chmod -R 755 ./hooks

# Or run as specific user in docker-compose.yml
services:
  mydia:
    user: "1000:1000"  # Match your host user ID
```

## Example Hooks

See `priv/hooks/after_media_added/01_example_anime_settings.lua` for a complete example hook that demonstrates:

- Accessing event data
- Conditional logic based on media properties
- Logging messages
- Returning modifications

## Reloading Hooks

Currently, hooks are loaded on application startup. To reload hooks after making changes:

```bash
# Restart the container
docker-compose restart mydia

# Or use the API (future feature)
# curl -X POST http://localhost:4000/api/hooks/reload \
#   -H "Authorization: Bearer $API_KEY"
```

## Security Considerations

1. **Sandboxing**: Lua hooks run in a sandboxed environment with limited access
2. **Timeouts**: Hooks are killed if they exceed the configured timeout
3. **File Access**: Hooks cannot directly access the filesystem (by design)
4. **Network Access**: HTTP helpers are rate-limited (future feature)
5. **Resource Limits**: Memory and CPU usage are constrained

## Performance

- Lua hooks have minimal overhead (~5-50ms typical)
- Hooks for `after_*` events run asynchronously by default (non-blocking)
- Hooks for `before_*` events run synchronously (blocking)
- Failed hooks don't block application flow (fail-soft design)

## Future Enhancements

- Hot reload without restart
- Web UI for hook management
- Hook testing/debugging interface
- External process hooks (bash/python/etc)
- Hook marketplace/community repository
