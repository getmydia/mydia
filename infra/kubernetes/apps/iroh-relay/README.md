# Changing the iroh-relay image

Read this before touching `image:` in `deployment.yaml`.

## Verify with real traffic, not --version

A `--version` check and a plain boot test both pass on an image that will
CrashLoopBackOff in production, because `iroh-relay` only panics once a packet
arrives. A container that has not yet received one looks perfectly healthy.

Use `verify-image.sh <image@digest>` in this directory. It boots the candidate
against the real `config.toml` extracted from `configmap.yaml`, sends UDP
datagrams at the QUIC and STUN listeners, and exits non-zero if the container
dies. It takes about 10 seconds.

## v1.0.3 is held back and must not be re-attempted blind

Rolled out 2026-08-19, went straight into CrashLoopBackOff, rolled back within
about 2 minutes:

```text
thread 'tokio-rt-worker' panicked at noq-udp-1.1.0/src/cmsg/mod.rs:81:5:
assertion failed: align_of::<T>() <= align_of::<C>()
```

This is n0-computer/noq#774, closed 2026-07-29. `noq-udp` panics on the first
received packet on any musl target: musl declares `cmsghdr` as align 4 and glibc
as align 8, while the `SCM_TIMESTAMPNS` arm decodes a `libc::timespec` of align 8.
`SO_TIMESTAMPNS` is set unconditionally on Linux, so it is deterministic rather
than data-dependent. The published relay image is a static musl build, and the
v1.0.3 image was built 2026-07-20, nine days before the fix.

Only iroh 1.0.3 moved to `noq ^1.1.0`; 1.0.1 and 1.0.2 are on `noq ^1.0.1`. So
v1.0.2 is the highest unaffected relay image, and it passes `verify-image.sh`.
Before trying v1.0.4 or later, confirm its image carries noq-udp 1.1.1 or newer.

Mydia's own crates are not affected, since all three `Cargo.lock` files already
resolve `noq-udp 1.1.1`. This is purely a property of the prebuilt relay image, so
do not change anything in `native/` or `player/rust/` in response to it.

## Pin by digest, tag alongside

Write `image: n0computer/iroh-relay:v1.0.0@sha256:<digest>`. The tag is for humans
reading the manifest and the digest is what selects the binary, so a re-published
tag cannot swap it. Resolve the OCI index digest, which is multi-platform, rather
than the amd64 sub-manifest, so the node still picks its own architecture.

## GA release tags are v-prefixed

Docker Hub publishes `v1.0.0`, `v1.0.1`, `v1.0.2` and `v1.0.3`, with `v1.0.3`
carrying `latest`. Earlier guidance held that 1.0+ drops the `v` prefix, and that
is wrong for GA releases. The unprefixed convention applied only to `1.0.0-rc.0`,
where the `v`-prefixed tag was a stale, segfaulting test build that caused a
roughly 3 minute CrashLoopBackOff in PR #137's rollout. Treat that as a
one-release anomaly and check the tag list before assuming either form:
https://hub.docker.com/r/n0computer/iroh-relay/tags

## Rollout mechanics

These manifests are not applied by any automation. `infra/deploy` has no phase for
this directory and there is no ArgoCD app for it, so merging a PR does not change
the cluster. Apply by hand on can-1 (`ssh can-1`, `sudo k3s kubectl`).

Copy only `deployment.yaml` and `kubectl diff -f` it first. Do not `apply -k` the
whole kustomization, which would also push namespace, configmap, pvc, service,
ingress and dns, any of which may have drifted live.

`replicas: 1` with `strategy: Recreate` means every apply is a real outage window.
Roll back with `kubectl set image` to the recorded digest if the pod is not Ready
within 90s or enters CrashLoopBackOff; do not wait out restart backoff.

## Verifying a rollout actually worked

A Ready pod only proves the process started. The relay's counters are process-local
and reset to 0 on restart, so a small `accepts_total` right after a rollout is
expected rather than traffic loss. Success is `accepts_total` growing and
`accepts_total - disconnects_total` climbing back to its pre-rollout value, which
was 4 nodes on 2026-08-19.

There is no public HTTPS path to test. The Service is ClusterIP with no Ingress
in the namespace, so 80 and 443 are not exposed through k8s at all, and only UDP
7842 (QUIC) and 3478 (STUN) have `hostPort`. Probe `/generate_204` against the
**pod IP from the node**; a 404 there is the relay answering, not a fault.

`relayserver_unique_client_keys_total` is useless and still broken in 1.0.3, where
`ClientCounter::default()` is built per connection actor rather than shared.
