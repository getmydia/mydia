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

    # Check if target GID is already in use by another group
    EXISTING_GROUP=$(getent group "$PGID" 2>/dev/null | cut -d: -f1)
    if [ -n "$EXISTING_GROUP" ] && [ "$EXISTING_GROUP" != "mydia" ]; then
        echo "  GID $PGID is already in use by group '$EXISTING_GROUP', removing it..."
        # Try multiple deletion methods
        if ! delgroup "$EXISTING_GROUP" 2>/dev/null && \
           ! groupdel "$EXISTING_GROUP" 2>/dev/null && \
           ! sed -i "/^$EXISTING_GROUP:/d" /etc/group 2>/dev/null; then
            echo "  Warning: Could not remove group '$EXISTING_GROUP', will work around it..."
        fi
    fi

    # Check if target UID is already in use by another user
    EXISTING_USER=$(getent passwd "$PUID" 2>/dev/null | cut -d: -f1)
    if [ -n "$EXISTING_USER" ] && [ "$EXISTING_USER" != "mydia" ]; then
        echo "  UID $PUID is already in use by user '$EXISTING_USER', removing it..."
        deluser "$EXISTING_USER" 2>/dev/null || userdel "$EXISTING_USER" 2>/dev/null || true
    fi

    # Try to update existing user/group, or recreate if it fails
    if ! groupmod -g "$PGID" mydia 2>/dev/null; then
        echo "  Recreating group with GID $PGID..."
        deluser mydia 2>/dev/null || true
        delgroup mydia 2>/dev/null || true
        addgroup -g "$PGID" mydia
        adduser -D -u "$PUID" -G mydia mydia
    elif ! usermod -u "$PUID" mydia 2>/dev/null; then
        echo "  Recreating user with UID $PUID..."
        deluser mydia 2>/dev/null || true
        adduser -D -u "$PUID" -G mydia mydia
    fi

    echo "  Successfully set mydia user to UID:GID $PUID:$PGID"
fi

# Ensure critical directories exist and have correct ownership
mkdir -p /config /data /media

# Only chown application directories, never /media
# /media may be a network mount (NFS/SMB) where chown is slow or fails
# Users should configure mount permissions via UID/GID mapping
chown -R "$PUID:$PGID" /config /data /app

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

# Give the app user access to the render node when one is bind-mounted.
#
# The gid that owns /dev/dri/renderD128 is assigned by the host and has no
# stable name inside the container: on a NixOS host it appears as the bare
# number 303, because Alpine has no matching /etc/group entry. So stat the
# device and add the gid, rather than looking up a group called "render" or
# "video" that may not exist.
#
# Many hosts ship the node 0666, where this is a no-op. Debian and Ubuntu
# commonly ship 0660 root:render, where without this the probe fails with
# Permission denied on a correctly configured host, and the operator reads
# that as Mydia not supporting their GPU.
#
# A host with no GPU is the common case, so every step below fails soft:
# nothing here may abort the entrypoint under `set -e`.
if [ -e /dev/dri/renderD128 ]; then
    RENDER_GID="$(stat -c '%g' /dev/dri/renderD128 2>/dev/null)" || RENDER_GID=""

    if [ -n "$RENDER_GID" ]; then
        if ! getent group "$RENDER_GID" >/dev/null 2>&1; then
            addgroup -g "$RENDER_GID" render 2>/dev/null || true
        fi

        RENDER_GROUP="$(getent group "$RENDER_GID" 2>/dev/null | cut -d: -f1)"

        if [ -n "$RENDER_GROUP" ]; then
            addgroup mydia "$RENDER_GROUP" 2>/dev/null || true
            echo "Granted mydia access to /dev/dri/renderD128 (group $RENDER_GROUP/$RENDER_GID)"
        fi
    fi
fi

echo "────────────────────────────────────────"
echo "Starting Mydia..."
echo "────────────────────────────────────────"

# Execute the main application as the mydia user
exec su-exec mydia "$@"
