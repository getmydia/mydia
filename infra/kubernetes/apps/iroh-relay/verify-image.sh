#!/usr/bin/env bash
#
# Verify an iroh-relay image before pointing production at it.
#
# Boots the candidate against this directory's real config.toml, then sends it
# actual UDP datagrams and checks it is still alive afterwards.
#
# The datagram step is the whole point. On 2026-08-19 the v1.0.3 image passed
# `--version` and passed a plain boot test, then went into CrashLoopBackOff the
# moment production traffic reached it: the published image is a static musl
# build carrying noq-udp 1.1.0, which panics on the first received packet
# (n0-computer/noq#774). A relay that has not yet received a packet looks
# perfectly healthy.
#
# Usage:
#   ./verify-image.sh n0computer/iroh-relay:v1.0.2@sha256:<digest>
#
# Exits 0 if the image survives, 1 if it does not. Requires docker and openssl.

set -u

IMG="${1:-}"
if [ -z "$IMG" ]; then
  echo "usage: $0 <image[@digest]>" >&2
  exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
NAME="iroh-relay-verify-$$"

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

# Throwaway cert. cert_mode is Manual, so the relay needs one to start; it is
# never validated by this test.
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/tls.key" -out "$WORK/tls.crt" \
  -days 1 -nodes -subj "/CN=cae1-1.relay.mydia.dev" >/dev/null 2>&1

# Use the real config, extracted from the ConfigMap rather than retyped, so the
# test cannot drift from what production actually runs.
python3 - "$HERE/configmap.yaml" "$WORK/config.toml" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
open(dst, "w").write(yaml.safe_load(open(src))["data"]["config.toml"])
PY

echo "==> booting $IMG"
if ! docker run -d --name "$NAME" \
  -v "$WORK:/config:ro" -v "$WORK:/certs:ro" \
  -p 18080:80 -p 18443:443 -p 19090:9090 -p 17842:7842/udp -p 13478:3478/udp \
  "$IMG" --config-path /config/config.toml >/dev/null; then
  echo "FAIL: container would not start"
  exit 1
fi

sleep 4
BEFORE="$(docker ps -a --filter "name=$NAME" --format '{{.Status}}')"
echo "    before datagrams: $BEFORE"
case "$BEFORE" in
  Up*) ;;
  *)
    echo "FAIL: died before receiving any traffic"
    docker logs "$NAME" 2>&1 | tail -20
    exit 1
    ;;
esac

echo "==> sending UDP datagrams to the QUIC and STUN listeners"
python3 - <<'PY'
import socket
for port in (17842, 13478):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for _ in range(5):
        s.sendto(b"\x00" * 64, ("127.0.0.1", port))
    s.close()
PY

sleep 4
AFTER="$(docker ps -a --filter "name=$NAME" --format '{{.Status}}')"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:18080/generate_204)"
echo "    after datagrams:  $AFTER"
echo "    generate_204:     $CODE"

case "$AFTER" in
  Up*) ;;
  *)
    echo "FAIL: crashed on receiving traffic"
    docker logs "$NAME" 2>&1 | tail -20
    exit 1
    ;;
esac

if [ "$CODE" != "204" ]; then
  echo "FAIL: expected 204 from /generate_204, got $CODE"
  docker logs "$NAME" 2>&1 | tail -20
  exit 1
fi

echo "PASS: $IMG survived real traffic"
