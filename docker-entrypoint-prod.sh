#!/bin/sh
set -e

# Default PUID and PGID to 1000 if not set
PUID=${PUID:-1000}
PGID=${PGID:-1000}

echo "
────────────────────────────────────────
    __  ___          ___
   /  |/  /_  ______/ (_)___ _
  / /|_/ / / / / __  / / __ \`/
 / /  / / /_/ / /_/ / / /_/ /
/_/  /_/\__, /\__,_/_/\__,_/
       /____/

────────────────────────────────────────
User UID:    $PUID
User GID:    $PGID
Timezone:    ${TZ:-UTC}
────────────────────────────────────────
"

# Get current UID and GID of mydia user
CURRENT_UID=$(id -u mydia 2>/dev/null || echo 1000)
CURRENT_GID=$(id -g mydia 2>/dev/null || echo 1000)

# Update user and group IDs if they differ
if [ "$PUID" != "$CURRENT_UID" ] || [ "$PGID" != "$CURRENT_GID" ]; then
    echo "Updating mydia user UID:GID to $PUID:$PGID..."

    # Update group ID if needed
    if [ "$PGID" != "$CURRENT_GID" ]; then
        groupmod -g "$PGID" mydia
    fi

    # Update user ID if needed
    if [ "$PUID" != "$CURRENT_UID" ]; then
        usermod -u "$PUID" mydia
    fi
fi

# Ensure critical directories exist and have correct ownership
mkdir -p /config /data /media
chown -R "$PUID:$PGID" /config /data /media /app

# Set timezone if provided
if [ -n "$TZ" ]; then
    if [ -f "/usr/share/zoneinfo/$TZ" ]; then
        ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
        echo "$TZ" > /etc/timezone
        echo "Timezone set to $TZ"
    else
        echo "Warning: Timezone $TZ not found, using UTC"
    fi
fi

echo "────────────────────────────────────────"
echo "Starting Mydia..."
echo "────────────────────────────────────────"

# Execute the main application as the mydia user
exec su-exec mydia "$@"
