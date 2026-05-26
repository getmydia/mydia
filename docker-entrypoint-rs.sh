#!/bin/bash
set -e

# Re-exec as the host user so files written under the bind mount
# (target/dx artifacts, sqlx prepare cache, tailwind output) end up
# owned by the human, not root. Mirrors docker-entrypoint.sh.

if [ "$(id -u)" = "0" ] && [ "${LOCAL_UID:-0}" != "0" ]; then
    uid="${LOCAL_UID}"
    gid="${LOCAL_GID:-$uid}"

    if ! getent group "$gid" > /dev/null 2>&1; then
        groupadd -g "$gid" devgroup
    fi
    if ! getent passwd "$uid" > /dev/null 2>&1; then
        useradd -u "$uid" -g "$gid" -m -s /bin/bash devuser
    fi

    DEV_USER=$(getent passwd "$uid" | cut -d: -f1)
    # passwd is name:pw:uid:gid:gecos:home:shell — field 6 is home.
    # `getent passwd | cut -f5` returns GECOS (empty by default), not
    # the home dir; using it gives us an empty path that silently
    # chowns "/" (or worse, fails open under set -e).
    USER_HOME=$(getent passwd "$uid" | cut -d: -f6)

    # Named-volume mount points start root-owned on first attach.
    # Chown the ones the dev user writes into. /usr/local/cargo is
    # the toolchain root — only registry/git subdirs change at
    # runtime, so we narrow the chown there.
    for dir in /usr/local/cargo/registry /usr/local/cargo/git /app/mydia-rs/target; do
        if [ -d "$dir" ]; then
            chown -R "$uid:$gid" "$dir" 2>/dev/null || true
        fi
    done

    # The named volume on /home/devuser/.dioxus makes docker auto-
    # create /home/devuser as root before the entrypoint runs;
    # useradd -m sees the dir exists and skips its own creation.
    # Without a non-recursive chown on $USER_HOME, devuser can't
    # write new files in their own home dir (only into the .dioxus
    # mount that we chown recursively below).
    chown "$uid:$gid" "$USER_HOME" 2>/dev/null || true
    mkdir -p "$USER_HOME/.cache" "$USER_HOME/.dioxus" "$USER_HOME/.cargo"
    chown -R "$uid:$gid" "$USER_HOME/.cache" "$USER_HOME/.dioxus" "$USER_HOME/.cargo"

    # dx's auto-downloaded tailwindcss + asset cache live under
    # ~/.dioxus. The image already ships /usr/local/bin/tailwindcss so
    # the download path is mostly cold, but the asset cache still uses
    # the directory.

    exec gosu "$DEV_USER" env LOCAL_UID=0 LOCAL_GID=0 \
        HOME="$USER_HOME" \
        PATH="$PATH" \
        "$0" "$@"
fi

# Post-Dioxus cutover: the embedded SPA is at mydia-rs/frontend/dist/
# and is auto-built by build.rs. No placeholder needed.

# Equivalent of the devenv enterShell exports — read by the running
# binary, not by dx itself. Same names as the devenv flake.
export MYDIA_RS_DEV_SKIP_LOCK="${MYDIA_RS_DEV_SKIP_LOCK:-true}"

exec "$@"
