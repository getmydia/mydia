#!/bin/sh
# Starts the experimental VPN (patched gluetun) when MYDIA_VPN_SERVICE_PROVIDER
# is set. Runs as root from the entrypoint. Never fails the boot: problems go
# into /config/gluetun/preflight, which Mydia shows in the admin UI.
set -u

[ -n "${MYDIA_VPN_SERVICE_PROVIDER:-}" ] || exit 0

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

printf 'net_admin=%s\ntun=%s\nsrc_valid_mark=%s\n' "$net_admin" "$tun" "$src_valid_mark" > "$dir/preflight"
chmod 644 "$dir/preflight"

if [ "$net_admin" = missing ] || [ "$tun" = missing ]; then
    echo "VPN: preflight failed (net_admin=$net_admin tun=$tun); torrents stay stopped"
    exit 0
fi

key=$(head -c 24 /dev/urandom | base64 | tr -d '/+=')
printf '%s' "$key" > "$dir/apikey"
chown mydia:mydia "$dir/apikey"
chmod 400 "$dir/apikey"

gid=$(getent group mydia-torrent | cut -d: -f3)

# MYDIA_VPN_FOO=bar becomes FOO=bar for gluetun. Mydia's own values are
# passed last so they win over any user attempt to set them.
gluetun_env=$(env | sed -n 's/^MYDIA_VPN_//p')

(
    while true; do
        # shellcheck disable=SC2086 # word splitting is the point: one VAR=value per word
        env -i PATH="$PATH" $gluetun_env \
            SPLIT_TUNNEL_GID="$gid" \
            HTTP_CONTROL_SERVER_ADDRESS=127.0.0.1:8000 \
            HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE="{\"auth\":\"apikey\",\"apikey\":\"$key\"}" \
            DNS_ADDRESS=127.0.0.1 \
            /usr/local/bin/gluetun >> "$dir/gluetun.log" 2>&1
        echo "gluetun exited with $?; restarting in 5s" >> "$dir/gluetun.log"
        sleep 5
    done
) &

echo "VPN: gluetun started for provider $MYDIA_VPN_SERVICE_PROVIDER (experimental)"
