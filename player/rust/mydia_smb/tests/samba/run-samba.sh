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
UNIX_USER="$(id -un)"
# The state names a directory this script later deletes with sudo, so it
# lives where only this user can write: XDG_RUNTIME_DIR, or a private
# directory of our own under the temp dir when that is unset.
STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}/mydia-smb-harness-$(id -u)}"
STATE_FILE="$STATE_DIR/mydia-smb-harness-$UNIX_USER.env"

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

# Every live process of this harness: the sudo wrappers, smbd and its
# samba-dcerpcd and rpcd_* helpers. smbd spawns the helpers on demand with
# --configfile=$DIR/smb.conf, so the recorded pids alone miss them. Matching
# the program name as well as the exact argument keeps this from picking up a
# shell whose command line merely mentions $DIR, or a pid reused since a
# stale state file was written.
harness_pids() {
  local pid exe args
  for pid in $(pgrep -f -- "$DIR/" 2>/dev/null || true); do
    [ "$pid" = "$$" ] && continue
    args=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || continue
    exe=${args%% *}
    case "${exe##*/}" in
      smbd | sudo | samba-dcerpcd | rpcd_*) ;;
      *) continue ;;
    esac
    case "$args" in
      *" --configfile=$DIR/"* | *" -s $DIR/smb.conf "* | *" -s $DIR/smb1.conf "*)
        echo "$pid"
        ;;
    esac
  done
}

# Waits up to 5s for the given pids to exit, then SIGKILLs the rest.
# Returns non-zero if any survive even that.
wait_gone() {
  local i pid alive
  for i in $(seq 1 50); do
    alive=""
    for pid in "$@"; do
      if sudo kill -0 "$pid" 2>/dev/null; then alive="$alive $pid"; fi
    done
    [ -z "$alive" ] && return 0
    sleep 0.1
  done
  log "still running after 5s, sending SIGKILL:$alive"
  # shellcheck disable=SC2086
  sudo kill -KILL $alive 2>/dev/null || true
  for i in $(seq 1 20); do
    alive=""
    for pid in "$@"; do
      if sudo kill -0 "$pid" 2>/dev/null; then alive="$alive $pid"; fi
    done
    [ -z "$alive" ] && return 0
    sleep 0.1
  done
  log "could not kill:$alive"
  return 1
}

# Kills every harness process and waits until each one has exited, so a
# restart never races an old smbd still holding its pidfile lock or port.
kill_pids() {
  local pids
  pids=$(harness_pids)
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086
  sudo kill $pids 2>/dev/null || true
  # shellcheck disable=SC2086
  wait_gone $pids
}

# A smbd that never listened leaves nothing else to debug from in CI.
dump_diagnostics() {
  local f
  for f in "$DIR"/smbd-*.out "$DIR"/main/log/* "$DIR"/smb1/log/*; do
    [ -f "$f" ] || continue
    echo "--- $f" >&2
    sudo cat "$f" >&2 2>/dev/null || cat "$f" >&2 || true
  done
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

# True when both smbd are still running: the sudo wrappers we started and
# the daemons named in their pidfiles.
smbd_alive() {
  local pid pidfile
  for pid in $PIDS; do
    kill -0 "$pid" 2>/dev/null || return 1
  done
  for pidfile in "$DIR"/main/run/smbd.pid "$DIR"/smb1/run/smbd.pid; do
    pid=$(cat "$pidfile" 2>/dev/null) || return 1
    sudo kill -0 "$pid" 2>/dev/null || return 1
  done
}

start_smbd() {
  PIDS=""
  local conf
  # No --no-process-group: smbd signals its whole process group when it
  # shuts down, so sharing the caller's group would SIGTERM whoever ran
  # start or restart (the test binary, the CI step) and the new smbd with it.
  for conf in "$DIR/smb.conf" "$DIR/smb1.conf"; do
    sudo "${SMBD[@]}" --foreground -s "$conf" \
      >"$DIR/smbd-$(basename "$conf").out" 2>&1 &
    PIDS="$PIDS $!"
  done
  # A smbd that binds and then quits (a stale pidfile lock, a bad config)
  # must fail here, not as a hung test later.
  if ! { wait_port "$PORT" && wait_port "$PORT_SMB1" && sleep 0.5 && smbd_alive; }; then
    log "smbd did not stay up"
    dump_diagnostics
    kill_pids || true
    exit 1
  fi
  {
    echo "DIR=$DIR"
    echo "PIDS=\"$PIDS\""
  } >"$STATE_FILE"
}

ensure_state_dir() {
  [ -n "${XDG_RUNTIME_DIR:-}" ] && return 0
  # Fails harmlessly when it already exists; the checks below decide.
  mkdir -m 700 "$STATE_DIR" 2>/dev/null || true
  if [ -L "$STATE_DIR" ] || [ ! -d "$STATE_DIR" ] || [ ! -O "$STATE_DIR" ]; then
    log "$STATE_DIR is not a directory of our own; refusing to use it"
    exit 1
  fi
  chmod 700 "$STATE_DIR"
}

# Reads the state as data (never sourced), and only from a file of our own
# naming a directory this script could have made.
load_state() {
  if [ ! -f "$STATE_FILE" ]; then
    log "no harness state at $STATE_FILE"
    return 1
  fi
  if [ ! -O "$STATE_FILE" ]; then
    log "$STATE_FILE is not ours; ignoring it"
    return 1
  fi
  local key value
  DIR=""
  PIDS=""
  while IFS='=' read -r key value; do
    value=${value#\"}
    value=${value%\"}
    case "$key" in
      DIR) DIR=$value ;;
      PIDS) PIDS=$value ;;
    esac
  done <"$STATE_FILE"
  case "$DIR" in
    /*/mydia-smb-??????) ;;
    *)
      log "unexpected harness dir in $STATE_FILE: $DIR"
      return 1
      ;;
  esac
  case "$DIR$PIDS" in
    *..* | *[!0-9A-Za-z/._\ -]*)
      log "unexpected characters in $STATE_FILE"
      return 1
      ;;
  esac
  case "$PIDS" in
    *[!0-9\ ]*)
      log "unexpected pids in $STATE_FILE: $PIDS"
      return 1
      ;;
  esac
}

ensure_state_dir

cmd=${1:-start}
case "$cmd" in
  start)
    if load_state 2>/dev/null && [ -d "$DIR" ]; then
      if smbd_alive; then
        log "already running (dir $DIR); run stop first"
        export_lines
        exit 0
      fi
      # A reboot, an OOM kill or a crashed smbd leaves the state behind:
      # exporting its ports would point the tests at nothing.
      log "smbd from $DIR is gone; cleaning up and starting afresh"
      kill_pids || true
      sudo rm -rf "$DIR" 2>/dev/null || rm -rf "$DIR"
      rm -f "$STATE_FILE"
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
