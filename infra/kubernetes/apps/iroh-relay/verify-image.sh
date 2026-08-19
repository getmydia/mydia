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
# tag, so without this the script can verify months-old bits and report PASS for
# an image nobody is about to deploy. Tags also get re-published; digests do not.
echo "==> pulling $IMG"
if ! docker pull "$IMG" >"$WORK/pull.log" 2>&1; then
  tail -3 "$WORK/pull.log" >&2
  echo "FAIL: could not pull $IMG" >&2
  echo "      (a problem with this machine or the reference, not a verdict on the image)" >&2
  exit 2
fi
# Take the digest from the pull itself. `docker pull -q` swallows this line, and
# an image's .RepoDigests can hold several references, so indexing that list is
# not guaranteed to name the thing that was just pulled.
DIGEST="$(sed -n 's/^Digest: //p' "$WORK/pull.log" | tail -1)"
if [ -z "$DIGEST" ]; then
  echo "FAIL: docker pull reported no digest for $IMG" >&2
  echo "      (a problem with this machine or the reference, not a verdict on the image)" >&2
  exit 2
fi
echo "    tested: $DIGEST"

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
# a bad image is reported as PASS. The UDP path cannot be probed for readiness
# first, because on a bad image the probe is the thing that kills it, so
# /generate_204 stands in as the readiness signal.
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

echo "    before traffic: $BEFORE"
if [ -z "$READY" ]; then
  case "$BEFORE" in
    Up*) echo "FAIL: never served /generate_204, so it never got to receive traffic" ;;
    *) echo "FAIL: died before receiving any traffic" ;;
  esac
  docker logs "$NAME" 2>&1 | tail -20 || true
  exit 1
fi

# Make the relay prove it received a datagram rather than inferring it from a
# still-running container. Under RFC 9000 a server that gets a long-header packet
# carrying a version it does not support answers with a Version Negotiation
# packet, so an answer here means the QUIC listener took the datagram off the
# socket, which is exactly the path noq-udp panics on.
#
# This has to be a positive check. Surviving unanswered proves nothing: on
# 2026-08-19 the datagrams this script aimed at port 3478 turned out to land on
# nothing at all, because with enable_quic_addr_discovery the relay binds only
# 7842 and the STUN port in deployment.yaml is left over from an older config.
# Silence and safety look identical from the outside.
echo "==> proving the QUIC listener receives traffic"
PROBE=0
python3 - <<'PY' || PROBE=$?
import os, socket, struct, sys


def probe():
    dcid, scid = os.urandom(8), os.urandom(8)
    pkt = (
        b"\xc0"                           # long header, fixed bit set
        + struct.pack(">I", 0x1A2A3A4A)   # deliberately unsupported version
        + bytes([len(dcid)]) + dcid
        + bytes([len(scid)]) + scid
    )
    pkt += b"\x00" * (1200 - len(pkt))    # short Initials may be discarded

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    try:
        s.sendto(pkt, ("127.0.0.1", 17842))
        data, _ = s.recvfrom(2048)
        return data
    except socket.timeout:
        return None
    finally:
        s.close()


# Three attempts, because UDP is allowed to drop one and because HTTP coming up
# does not prove 7842 is bound yet. A retry costs nothing on a bad image: the
# first datagram has already killed it by then.
for _ in range(3):
    data = probe()
    if data is None:
        continue
    if len(data) >= 5 and data[0] & 0x80 and struct.unpack(">I", data[1:5])[0] == 0:
        print("    version negotiation answered: the datagram was received")
        sys.exit(0)
    print(f"    answered with {len(data)} bytes, but not a version negotiation packet")
    sys.exit(1)

print("    no answer from the QUIC listener after 3 attempts")
sys.exit(1)
PY

# Then spray every UDP port the deployment exposes, so a listener added to the
# config later is covered too. Two rounds a second apart, since a datagram that
# lands a moment early is lost rather than queued.
echo "==> sending plain datagrams to every exposed UDP port"
python3 - <<'PY'
import socket, time

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
echo "    after traffic:  $AFTER"
echo "    generate_204:   $CODE"

case "$AFTER" in
  Up*) ;;
  *)
    echo "FAIL: crashed on receiving traffic"
    docker logs "$NAME" 2>&1 | tail -20 || true
    exit 1
    ;;
esac

if [ "$PROBE" -ne 0 ]; then
  echo "FAIL: still up, but never proved it received a datagram"
  docker logs "$NAME" 2>&1 | tail -20 || true
  exit 1
fi

if [ "$CODE" != "204" ]; then
  echo "FAIL: expected 204 from /generate_204, got $CODE"
  docker logs "$NAME" 2>&1 | tail -20
  exit 1
fi

echo "PASS: $IMG received real traffic and survived it"
