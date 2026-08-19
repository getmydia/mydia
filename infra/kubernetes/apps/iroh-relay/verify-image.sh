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
# Exits 0 if the image survives, 1 if it does not, 2 on bad usage or a missing
# dependency. Requires docker, openssl, curl, and python3 with PyYAML.
#
# Dependencies are preflighted rather than discovered mid-run. Without that, a
# missing python3 or PyYAML leaves no config.toml, the relay exits for want of
# config, and the script blames the candidate image for a broken harness. That
# misattribution is the failure worth guarding against here: it would send
# someone hunting a relay bug that does not exist.

set -euo pipefail

IMG="${1:-}"
if [ -z "$IMG" ]; then
  echo "usage: $0 <image[@digest]>" >&2
  exit 2
fi

missing=""
for bin in docker openssl curl python3; do
  command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"
done
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  missing="$missing python3-PyYAML"
fi
if [ -n "$missing" ]; then
  echo "FAIL: missing dependencies:$missing" >&2
  echo "      (this is a problem with this machine, not with $IMG)" >&2
  exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
NAME="iroh-relay-verify-$$"

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK" || true
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

# Fetch the candidate before running it. `docker run` reuses a matching local
# tag, so without this the script can verify a months-old image and report PASS
# for bits nobody is about to deploy. Tags also get re-published; digests do not,
# which is why the deployment pins one and why the run below prints the digest it
# actually tested.
echo "==> pulling $IMG"
if ! docker pull -q "$IMG" >/dev/null; then
  echo "FAIL: could not pull $IMG" >&2
  echo "      (a problem with this machine or the reference, not a verdict on the image)" >&2
  exit 2
fi
docker image inspect --format '{{if .RepoDigests}}    tested: {{index .RepoDigests 0}}{{end}}' "$IMG" 2>/dev/null || true

echo "==> booting $IMG"
if ! docker run -d --name "$NAME" \
  -v "$WORK:/config:ro" -v "$WORK:/certs:ro" \
  -p 18080:80 -p 18443:443 -p 19090:9090 -p 17842:7842/udp -p 13478:3478/udp \
  "$IMG" --config-path /config/config.toml >/dev/null; then
  echo "FAIL: container would not start"
  exit 1
fi

# Wait for the relay to actually serve before sending it anything. A container in
# state Up has a process, not a bound socket, and a datagram that arrives before
# the listeners come up is dropped rather than queued: the panic never fires and
# a bad image is reported as PASS. The UDP path cannot be probed first, because
# on a bad image the probe is the thing that kills it, so /generate_204 stands in
# as the readiness signal.
echo "==> waiting for the relay to serve HTTP"
BEFORE=""
READY=""
for _ in $(seq 1 30); do
  BEFORE="$(docker ps -a --filter "name=$NAME" --format '{{.Status}}')"
  case "$BEFORE" in
    Up*) ;;
    *) break ;;
  esac
  if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:18080/generate_204 || true)" = "204" ]; then
    READY=1
    break
  fi
  sleep 1
done

echo "    before datagrams: $BEFORE"
if [ -z "$READY" ]; then
  case "$BEFORE" in
    Up*) echo "FAIL: never served /generate_204, so it never got to receive traffic" ;;
    *) echo "FAIL: died before receiving any traffic" ;;
  esac
  docker logs "$NAME" 2>&1 | tail -20 || true
  exit 1
fi

echo "==> sending UDP datagrams to the QUIC and STUN listeners"
python3 - <<'PY'
import socket, time

# Two rounds, a second apart. Serving HTTP does not strictly prove the UDP
# listeners are bound, and a datagram that lands a moment too early is lost
# rather than queued, which would let a bad image through unscathed.
for _ in range(2):
    for port in (17842, 13478):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        for _ in range(5):
            s.sendto(b"\x00" * 64, ("127.0.0.1", port))
        s.close()
    time.sleep(1)
PY

sleep 4
AFTER="$(docker ps -a --filter "name=$NAME" --format '{{.Status}}')"
# curl exits non-zero on connection refused, which is exactly the crash case this
# script reports on, so it must not abort under set -e.
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:18080/generate_204 || true)"
echo "    after datagrams:  $AFTER"
echo "    generate_204:     $CODE"

case "$AFTER" in
  Up*) ;;
  *)
    echo "FAIL: crashed on receiving traffic"
    docker logs "$NAME" 2>&1 | tail -20 || true
    exit 1
    ;;
esac

if [ "$CODE" != "204" ]; then
  echo "FAIL: expected 204 from /generate_204, got $CODE"
  docker logs "$NAME" 2>&1 | tail -20
  exit 1
fi

echo "PASS: $IMG survived real traffic"
