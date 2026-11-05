#!/bin/sh
# Starts the experimental VPN (patched gluetun) when MYDIA_VPN_SERVICE_PROVIDER
# is set. Runs as root from the entrypoint. Never fails the boot: problems go
# into /config/gluetun/preflight, which Mydia shows in the admin UI.
set -u

# Runs $1 with the environment gluetun gets. MYDIA_VPN_FOO=bar becomes
# FOO=bar. The one exception is the provider: gluetun reads
# VPN_SERVICE_PROVIDER, so MYDIA_VPN_SERVICE_PROVIDER is passed under that
# name too (without it gluetun falls back to its default provider). Mydia's own
# values come last so they win over any user attempt to set them. DNS_SERVER
# stays on: split DNS needs gluetun's resolver. $2 is the split group's gid and
# $3 the control server's API key.
#
# Each value is read from its variable and passed as one argument, so spaces,
# quotes, * and ? reach gluetun unchanged. Only the names come from `env`, which
# cannot tell a newline inside a value from the start of the next variable: a
# name that is not actually set is skipped.
run_with_gluetun_env() {
    bin=$1
    split_gid=$2
    api_key=$3
    isset=
    value=
    set --
    for name in $(env | sed -n 's/^\(MYDIA_VPN_[A-Za-z0-9_]*\)=.*/\1/p'); do
        eval "isset=\${$name+x}"
        [ -n "$isset" ] || continue
        eval "value=\${$name}"
        set -- "$@" "${name#MYDIA_VPN_}=$value"
    done
    env -i PATH="$PATH" "$@" \
        VPN_SERVICE_PROVIDER="$MYDIA_VPN_SERVICE_PROVIDER" \
        SPLIT_TUNNEL_GID="$split_gid" \
        HTTP_CONTROL_SERVER_ADDRESS=127.0.0.1:8000 \
        HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE="{\"auth\":\"apikey\",\"apikey\":\"$api_key\"}" \
        DNS_ADDRESS=127.0.0.1 \
        DNS_SERVER=on \
        "$bin"
}

# Tests source this file for the function above and stop here.
if [ "${VPN_PREFLIGHT_FUNCTIONS_ONLY:-}" = 1 ]; then
    # shellcheck disable=SC2317 # exit is the fallback when run, not sourced
    return 0 2>/dev/null || exit 0
fi

# A provider of only whitespace counts as unset, as it does in Mydia.
[ -n "$(printf '%s' "${MYDIA_VPN_SERVICE_PROVIDER:-}" | tr -d '[:space:]')" ] || exit 0

# The VPN only serves the built-in client, so it stays down when that is off.
case "$(printf '%s' "${MYDIA_TORRENT_ENABLED:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    false | 0 | no | off)
        echo "VPN: not started because MYDIA_TORRENT_ENABLED turns the built-in torrent client off"
        exit 0
        ;;
esac

dir=/config/gluetun
mkdir -p "$dir"
chown mydia:mydia "$dir"

# CAP_NET_ADMIN is bit 12 of the effective capability mask.
net_admin=missing
capeff=$(awk '/^CapEff/ {print $2}' /proc/self/status)
[ $(( (0x$capeff >> 12) & 1 )) -eq 1 ] && net_admin=ok
tun=ok
[ -c /dev/net/tun ] || tun=missing

# Informational: strict reverse path filtering (rp_filter=1) drops replies on
# the tunnel unless this sysctl is 1. Docker mounts /proc/sys read-only, so
# gluetun cannot set it; the container needs `sysctls:` in its compose file.
# Mydia does not parse this key yet and the VPN does not fail on it.
src_valid_mark=missing
[ "$(cat /proc/sys/net/ipv4/conf/all/src_valid_mark 2>/dev/null)" = 1 ] && src_valid_mark=ok

# The split group must exist and differ from mydia's own gid, or the setgid
# binaries would not be told apart from the rest of Mydia's traffic.
gid=$(getent group mydia-torrent | cut -d: -f3)
split_group=ok
if [ -z "$gid" ] || [ "$gid" = "$(id -g mydia)" ]; then
    split_group=missing
fi

printf 'net_admin=%s\ntun=%s\nsplit_group=%s\nsrc_valid_mark=%s\n' \
    "$net_admin" "$tun" "$split_group" "$src_valid_mark" > "$dir/preflight"
chmod 644 "$dir/preflight"

if [ "$net_admin" = missing ] || [ "$tun" = missing ] || [ "$split_group" = missing ]; then
    # A key left by an earlier boot would point Mydia at a gluetun that is gone.
    rm -f "$dir/apikey"
    echo "VPN: preflight failed (net_admin=$net_admin tun=$tun split_group=$split_group); torrents stay stopped"
    [ "$split_group" = ok ] || echo "VPN: group mydia-torrent is missing or shares mydia's gid (PGID); recreate the container or pick another PGID"
    exit 0
fi

(
    umask 077
    key=$(head -c 24 /dev/urandom | base64 | tr -d '/+=')
    printf '%s' "$key" > "$dir/apikey"
)
chown mydia:mydia "$dir/apikey"
chmod 400 "$dir/apikey"
key=$(cat "$dir/apikey")

(
    while true; do
        run_with_gluetun_env /usr/local/bin/gluetun "$gid" "$key" >> "$dir/gluetun.log" 2>&1
        echo "gluetun exited with $?; restarting in 5s" >> "$dir/gluetun.log"
        sleep 5
    done
) &

echo "VPN: gluetun started for provider $MYDIA_VPN_SERVICE_PROVIDER (experimental)"
