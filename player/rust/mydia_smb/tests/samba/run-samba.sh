#!/usr/bin/env bash
# Throwaway Samba for the mydia_smb tests. Never listens beyond loopback.
#
#   run-samba.sh [start]   start two smbd (4455 SMB3, 4456 NT1), print export lines
#   run-samba.sh stop      kill both and delete the temp dir
#   run-samba.sh restart   restart the smbd processes, keeping dir, conf, fixtures
#
# Usage in a shell:  eval "$(run-samba.sh)"
set -euo pipefail

PORT=4455
PORT_SMB1=4456
SMB_USER=mydia
SMB_PASS=mydia-test
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/mydia-smb-harness-$(id -un).env"
UNIX_USER="$(id -un)"

if command -v smbd >/dev/null 2>&1; then
  SMBD=(smbd)
  SMBPASSWD=(smbpasswd)
else
  SMBD=(nix shell nixpkgs#samba --command smbd)
  SMBPASSWD=(nix shell nixpkgs#samba --command smbpasswd)
fi
# sudo drops PATH on some systems, so resolve the binary up front.
SMBD_BIN="$(command -v smbd || true)"
if [ -n "$SMBD_BIN" ]; then SMBD=("$SMBD_BIN"); fi

log() { echo "run-samba: $*" >&2; }

export_lines() {
  cat <<EXP
export MYDIA_SMB_TEST_HOST=127.0.0.1
export MYDIA_SMB_TEST_PORT=$PORT
export MYDIA_SMB_TEST_USER=$SMB_USER
export MYDIA_SMB_TEST_PASSWORD=$SMB_PASS
export MYDIA_SMB_TEST_SMB1_PORT=$PORT_SMB1
EXP
}

kill_pids() {
  local pidfile
  for pidfile in "$DIR"/run/smbd-*.pid "$DIR"/run1/smbd-*.pid; do
    [ -f "$pidfile" ] || continue
    sudo kill "$(cat "$pidfile")" 2>/dev/null || true
  done
  [ -n "${PIDS:-}" ] && sudo kill $PIDS 2>/dev/null || true
  sleep 0.5
}

wait_port() {
  local port=$1 i
  for i in $(seq 1 100); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  log "port $port never accepted"
  return 1
}

write_conf() {
  # $1 = conf path, $2 = port, $3 = state subdir, $4 = extra [global] lines
  local conf=$1 port=$2 sub=$3 extra=$4
  mkdir -p "$DIR/$sub"/{lock,run,priv,cache,state,log,ncalrpc}
  cat >"$conf" <<CONF
[global]
  workgroup = WORKGROUP
  server string = mydia-smb-test
  interfaces = lo
  bind interfaces only = yes
  smb ports = $port
  disable netbios = yes
  load printers = no
  printcap name = /dev/null
  disable spoolss = yes
  map to guest = bad user
  guest account = $UNIX_USER
  username map = $DIR/usermap
  security = user
  passdb backend = tdbsam:$DIR/$sub/priv/passdb.tdb
  lock directory = $DIR/$sub/lock
  state directory = $DIR/$sub/state
  cache directory = $DIR/$sub/cache
  pid directory = $DIR/$sub/run
  private dir = $DIR/$sub/priv
  ncalrpc dir = $DIR/$sub/ncalrpc
  log file = $DIR/$sub/log/log.%m
  logging = file
  $extra

[guest]
  path = $DIR/share
  guest ok = yes
  read only = yes

[auth]
  path = $DIR/share
  valid users = $UNIX_USER
  read only = no
  force user = $UNIX_USER

[enc]
  path = $DIR/share
  valid users = $UNIX_USER
  read only = yes
  smb encrypt = required
  force user = $UNIX_USER

[smb1]
  path = $DIR/share
  valid users = $UNIX_USER
  read only = yes
  force user = $UNIX_USER
CONF
}

make_fixtures() {
  mkdir -p "$DIR/share/Fable of Glass (2031)" "$DIR/share/denied"
  # byte i = (i * 31 + 7) % 251, 64 MiB
  python3 -I - "$DIR/share/Fable of Glass (2031)/Fable of Glass (2031).mkv" <<'PY'
import sys
n = 64 * 1024 * 1024
period = bytes((i * 31 + 7) % 251 for i in range(251))
reps = n // 251 + 1
with open(sys.argv[1], "wb") as f:
    f.write((period * reps)[:n])
PY
  # '?' is illegal on the wire. Clients (smb2, macOS) store it as U+F025, so the
  # fixture does too, or Samba would hand back a mangled 8.3 name instead.
  head -c 1024 /dev/zero | tr '\0' 'x' >"$DIR/share/Odd #1 50% $(printf '\357\200\245')é.mkv"
  echo "hidden" >"$DIR/share/denied/secret.txt"
  chmod 000 "$DIR/share/denied/secret.txt" "$DIR/share/denied"
}

start_smbd() {
  PIDS=""
  local conf
  for conf in "$DIR/smb.conf" "$DIR/smb1.conf"; do
    sudo "${SMBD[@]}" --foreground --no-process-group -s "$conf" \
      >"$DIR/smbd-$(basename "$conf").out" 2>&1 &
    PIDS="$PIDS $!"
  done
  wait_port "$PORT"
  wait_port "$PORT_SMB1"
  {
    echo "DIR=$DIR"
    echo "PIDS=\"$PIDS\""
  } >"$STATE_FILE"
}

load_state() {
  if [ ! -f "$STATE_FILE" ]; then
    log "no harness state at $STATE_FILE"
    return 1
  fi
  # shellcheck disable=SC1090
  . "$STATE_FILE"
}

cmd=${1:-start}
case "$cmd" in
  start)
    if load_state 2>/dev/null && [ -d "$DIR" ]; then
      log "already running (dir $DIR); run stop first"
      export_lines
      exit 0
    fi
    DIR="$(mktemp -d "${TMPDIR:-/tmp}/mydia-smb-XXXXXX")"
    chmod 755 "$DIR"
    printf '%s = %s\n' "$UNIX_USER" "$SMB_USER" >"$DIR/usermap"
    make_fixtures
    write_conf "$DIR/smb.conf" "$PORT" main ""
    write_conf "$DIR/smb1.conf" "$PORT_SMB1" smb1 "server min protocol = NT1
  server max protocol = NT1
  ntlm auth = yes
  lanman auth = yes"
    for sub in main smb1; do
      conf="$DIR/smb.conf"; [ "$sub" = smb1 ] && conf="$DIR/smb1.conf"
      printf '%s\n%s\n' "$SMB_PASS" "$SMB_PASS" | sudo "${SMBPASSWD[@]}" -c "$conf" -a -s "$UNIX_USER" >/dev/null
    done
    start_smbd
    export_lines
    ;;
  stop)
    load_state || exit 0
    kill_pids
    sudo rm -rf "$DIR" 2>/dev/null || rm -rf "$DIR"
    rm -f "$STATE_FILE"
    ;;
  restart)
    load_state
    kill_pids
    start_smbd
    export_lines
    ;;
  *)
    echo "usage: $0 [start|stop|restart]" >&2
    exit 2
    ;;
esac
