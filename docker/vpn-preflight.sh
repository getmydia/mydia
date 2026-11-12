#!/bin/sh
# Checks what the experimental VPN (patched gluetun) needs, then supervises
# gluetun from a background loop. Runs as root from the entrypoint. Never fails
# the boot: problems go into /config/gluetun/preflight, which Mydia shows in
# the admin UI.
#
# The VPN is configured from the admin UI, which writes
# /config/gluetun/settings/settings.env, or from MYDIA_VPN_* in the container
# environment, which wins. The loop polls the file every 2 seconds and starts,
# restarts or stops gluetun to match.
#
# Trust boundary: Mydia runs as the unprivileged user mydia, and everything
# under /config belongs to mydia, so a compromised Mydia can swap any path
# there for a symlink at any time, /config/gluetun itself included. Root
# therefore never opens a path under /config: every read and write there runs
# as mydia (through $as_mydia), so a planted symlink gains nothing mydia could
# not already do. The settings file is copied as mydia into a root-private
# snapshot, and root parses only the snapshot, with an allowlist and no eval.
# What gluetun trusts (its control server's auth file) lives in the
# root-private directory /run/mydia-vpn.
set -u

# Runs the rest of its command line as mydia. Tests set VPN_AS_MYDIA=env to
# run it as the current user.
as_mydia=${VPN_AS_MYDIA:-su-exec mydia}

auth_toml=/run/mydia-vpn/auth.toml
gluetun_bin=/usr/local/bin/gluetun

# The settings-file keys passed to gluetun, by name. VPN_ENABLED is read by
# the loop and never passed on.
settings_key_allowed() {
    case $1 in
        VPN_SERVICE_PROVIDER | VPN_TYPE | OPENVPN_USER | OPENVPN_PASSWORD | \
            WIREGUARD_PRIVATE_KEY | WIREGUARD_ADDRESSES | SERVER_COUNTRIES | \
            SERVER_REGIONS | SERVER_CITIES | SERVER_HOSTNAMES | VPN_PORT_FORWARDING)
            return 0
            ;;
    esac
    return 1
}

# True for a string of only whitespace, which counts as unset, as in Mydia.
blank() {
    [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]
}

# Runs $1 with the environment gluetun gets, replacing this shell (exec), so
# a background caller's $! is gluetun's pid. $2 is the split group's gid and
# $3 the settings snapshot. In order, later ones winning under `env -i`:
#
# 1. allowlisted KEY=value lines from the snapshot, passed byte for byte;
# 2. the operator's MYDIA_VPN_FOO=bar as FOO=bar, plus
#    MYDIA_VPN_SERVICE_PROVIDER as VPN_SERVICE_PROVIDER, the name gluetun
#    reads. A blank value for a key the UI also sets is skipped, so it does
#    not erase the file's value (Mydia treats it as unset too);
# 3. Mydia's own values, so they win over any user attempt to set them.
#    DNS_SERVER stays on: split DNS needs gluetun's resolver. The control
#    server's only role comes from the root-owned auth file, and the empty
#    default role grants nothing, so a route that file does not list is
#    refused.
#
# Each value is passed as one argument, so spaces, quotes, $, * and ? reach
# gluetun unchanged. Env names come from `env`, which cannot tell a newline
# inside a value from the start of the next variable: a name that is not
# actually set is skipped.
run_with_gluetun_env() {
    bin=$1
    split_gid=$2
    settings=$3
    isset=
    value=
    set --
    if [ -f "$settings" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case $line in
                *=*) settings_key_allowed "${line%%=*}" && set -- "$@" "$line" ;;
            esac
        done < "$settings"
    fi
    for name in $(env | sed -n 's/^\(MYDIA_VPN_[A-Za-z0-9_]*\)=.*/\1/p'); do
        eval "isset=\${$name+x}"
        [ -n "$isset" ] || continue
        eval "value=\${$name}"
        key=${name#MYDIA_VPN_}
        if blank "$value" && { settings_key_allowed "$key" || [ "$key" = SERVICE_PROVIDER ]; }; then
            continue
        fi
        set -- "$@" "$key=$value"
    done
    blank "${MYDIA_VPN_SERVICE_PROVIDER:-}" ||
        set -- "$@" "VPN_SERVICE_PROVIDER=$MYDIA_VPN_SERVICE_PROVIDER"
    exec env -i PATH="$PATH" "$@" \
        SPLIT_TUNNEL_GID="$split_gid" \
        HTTP_CONTROL_SERVER_ADDRESS=127.0.0.1:8000 \
        HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH="$auth_toml" \
        HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE='{}' \
        DNS_ADDRESS=127.0.0.1 \
        DNS_SERVER=on \
        "$bin"
}

# Reads the snapshot $1 into settings_enabled (true only for VPN_ENABLED=true,
# last line wins), dropped (comma-separated keys outside the allowlist, each
# once) and invalid (the count of lines that are not KEY=value with an
# upper-case key). Invalid lines are only counted: their text never reaches a
# file mydia can read.
read_settings_file() {
    settings_enabled=false
    dropped=
    invalid=0
    [ -f "$1" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        key=${line%%=*}
        case $line in
            *=*) ;;
            *) key= ;;
        esac
        case $key in
            '' | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*)
                invalid=$((invalid + 1))
                ;;
            VPN_ENABLED)
                settings_enabled=false
                [ "${line#*=}" = true ] && settings_enabled=true
                ;;
            *)
                settings_key_allowed "$key" && continue
                case ",$dropped," in
                    *",$key,"*) ;;
                    *) dropped=${dropped:+$dropped,}$key ;;
                esac
                ;;
        esac
    done < "$1"
    return 0
}

# Copies the settings file $1, read as mydia and capped at 64 KiB, to the
# root-private snapshot $2 and prints the snapshot's sha256, or `none` with an
# empty snapshot when the file cannot be read. The timeout covers a FIFO
# planted in place of the file.
snapshot_settings() {
    # shellcheck disable=SC2086 # $as_mydia is a command prefix
    if $as_mydia timeout 5 head -c 65536 "$1" > "$2" 2>/dev/null; then
        printf '%s' "$(sha256sum < "$2" | cut -d' ' -f1)"
    else
        : > "$2"
        printf none
    fi
}

# Writes stdin to $1 as mydia with mode $2, through a temp file and a rename.
write_as_mydia() {
    # shellcheck disable=SC2016,SC2086 # the script runs in mydia's shell
    $as_mydia sh -c 'umask 077; tmp="$1.tmp"; rm -f "$tmp" && cat > "$tmp" && chmod "$2" "$tmp" && mv -f "$tmp" "$1"' \
        sh "$1" "$2"
}

# Appends the line $1 to the gluetun log, as mydia.
log_line() {
    # shellcheck disable=SC2016,SC2086 # the script runs in mydia's shell
    printf '%s\n' "$1" | $as_mydia sh -c 'cat >> "$1"' sh "$log"
}

# Writes gluetun's control-server auth file $1: one role, authenticated by the
# API key $2, allowed only the three read routes Mydia uses. gluetun refuses
# every other route, so the key cannot change settings or stop the VPN.
write_auth_toml() {
    rm -f "$1"
    (
        umask 077
        printf '%s\n' \
            '[[roles]]' \
            'name = "mydia"' \
            'auth = "apikey"' \
            "apikey = \"$2\"" \
            'routes = ["GET /v1/vpn/status", "GET /v1/publicip/ip", "GET /v1/portforward"]' \
            > "$1"
    )
}

# Writes the loop status $1: the hash of the settings the loop last acted on
# ($2), the dropped keys ($3) and, when nonzero, the invalid-line count ($4).
write_loop_status() {
    {
        printf 'hash=%s\ndropped=%s\n' "$2" "$3"
        [ "${4:-0}" = 0 ] || printf 'invalid=%s\n' "$4"
    } | write_as_mydia "$1" 644
}

# Prints 1 when the VPN should run: the settings file enables it ($1 is
# `true`) or the environment names a provider.
vpn_wanted() {
    if [ "$1" = true ] || ! blank "${MYDIA_VPN_SERVICE_PROVIDER:-}"; then
        printf 1
    else
        printf 0
    fi
}

# Prints the loop's next step: start, restart, stop or none. $1 is 1 when
# gluetun runs, $2 is 1 when the VPN is wanted, $3 the settings hash gluetun
# was started with and $4 the current one.
loop_action() {
    if [ "$2" = 1 ]; then
        if [ "$1" != 1 ]; then
            printf start
        elif [ "$3" != "$4" ]; then
            printf restart
        else
            printf none
        fi
    elif [ "$1" = 1 ]; then
        printf stop
    else
        printf none
    fi
}

# The gluetun log lives on the persistent /config volume, next to the
# database, and a gluetun that fails at startup restarts every 5s. Before each
# start, a log over $2 bytes (5 MiB by default) moves to $1.1, replacing the
# previous one, so the two files stay bounded however long the loop runs.
# Mydia reads only the tail of the current log. The loop runs this as mydia.
rotate_log() {
    size=$(wc -c 2>/dev/null < "$1" || echo 0)
    if [ "$size" -gt "${2:-5242880}" ]; then
        mv -f "$1" "$1.1"
    fi
}

# True while process $1 runs. An exited child not yet reaped (a zombie)
# counts as gone.
alive() {
    [ -r "/proc/$1/stat" ] || return 1
    [ "$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -c1)" != Z ]
}

# Starts gluetun in the background on the current snapshot. Its output goes
# through a root-private FIFO to a writer running as mydia, which appends to
# the log.
start_gluetun() {
    # shellcheck disable=SC2016,SC2086 # the script runs in mydia's shell
    VPN_PREFLIGHT_FUNCTIONS_ONLY=1 $as_mydia sh -c '. "$1" && rotate_log "$2"' sh "$self" "$log"
    rm -f "$fifo"
    mkfifo -m 600 "$fifo"
    # shellcheck disable=SC2016,SC2086 # the script runs in mydia's shell
    $as_mydia sh -c 'exec cat >> "$1"' sh "$log" < "$fifo" &
    writer=$!
    run_with_gluetun_env "$gluetun_bin" "$gid" "$snapshot" > "$fifo" 2>&1 &
    pid=$!
}

# Stops gluetun: TERM, then KILL after 30 seconds.
stop_gluetun() {
    kill -TERM "$pid" 2>/dev/null
    i=0
    while alive "$pid" && [ "$i" -lt 30 ]; do
        sleep 1
        i=$((i + 1))
    done
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    wait "$writer" 2>/dev/null
    pid=
}

# Every 2 seconds: snapshot the settings, then start, restart or stop gluetun
# to match. loop-status is rewritten after every start or stop, and whenever
# the settings change, so Mydia can tell its file was applied.
supervise() {
    pid=
    writer=
    started=
    reported=
    while :; do
        hash=$(snapshot_settings "$dir/settings/settings.env" "$snapshot")
        read_settings_file "$snapshot"

        if [ -n "$pid" ] && ! alive "$pid"; then
            code=0
            wait "$pid" || code=$?
            wait "$writer" 2>/dev/null
            pid=
            log_line "gluetun exited with $code; restarting in 5s"
            sleep 5
            continue
        fi

        running=0
        [ -n "$pid" ] && running=1
        case $(loop_action "$running" "$(vpn_wanted "$settings_enabled")" "$started" "$hash") in
            start)
                start_gluetun
                started=$hash
                ;;
            restart)
                stop_gluetun
                start_gluetun
                started=$hash
                ;;
            stop)
                stop_gluetun
                started=
                ;;
            *)
                if [ "$hash" = "$reported" ]; then
                    sleep 2
                    continue
                fi
                ;;
        esac
        write_loop_status "$dir/loop-status" "$hash" "$dropped" "$invalid"
        reported=$hash
        sleep 2
    done
}

# Tests source this file for the functions above and stop here.
if [ "${VPN_PREFLIGHT_FUNCTIONS_ONLY:-}" = 1 ]; then
    # shellcheck disable=SC2317 # exit is the fallback when run, not sourced
    return 0 2>/dev/null || exit 0
fi

# The VPN only serves the built-in client, so it stays down when that is off.
case "$(printf '%s' "${MYDIA_TORRENT_ENABLED:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    false | 0 | no | off)
        echo "VPN: not started because MYDIA_TORRENT_ENABLED turns the built-in torrent client off"
        exit 0
        ;;
esac

self=$0
dir=/config/gluetun
log=$dir/gluetun.log
run=${auth_toml%/*}
snapshot=$run/settings.env
fifo=$run/gluetun.fifo

# /run belongs to root, so mydia cannot plant anything here.
mkdir -p "$run"
chmod 700 "$run"
# shellcheck disable=SC2086 # $as_mydia is a command prefix
$as_mydia mkdir -p "$dir"

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
    "$net_admin" "$tun" "$split_group" "$src_valid_mark" |
    write_as_mydia "$dir/preflight" 644

if [ "$net_admin" = missing ] || [ "$tun" = missing ] || [ "$split_group" = missing ]; then
    # A key left by an earlier boot would point Mydia at a gluetun that is gone.
    # shellcheck disable=SC2086 # $as_mydia is a command prefix
    $as_mydia rm -f "$dir/apikey"
    echo "VPN: preflight failed (net_admin=$net_admin tun=$tun split_group=$split_group); the VPN cannot start"
    [ "$split_group" = ok ] || echo "VPN: group mydia-torrent is missing or shares mydia's gid (PGID); recreate the container or pick another PGID"
    exit 0
fi

key=$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n')
printf '%s' "$key" | write_as_mydia "$dir/apikey" 400
write_auth_toml "$auth_toml" "$key"

supervise &

echo "VPN: supervisor started; gluetun runs while the admin UI or MYDIA_VPN_SERVICE_PROVIDER enables the VPN (experimental)"
