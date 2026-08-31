# Native crates: NIFs and p2p

## Every new NIF crate needs its own .cargo/config.toml

A crate under `native/` needs this file, or the Alpine images fail to build:

```toml
[target.'cfg(target_os = "macos")']
rustflags = ["-C", "link-arg=-undefined", "-C", "link-arg=dynamic_lookup"]

[target.'cfg(target_env = "musl")']
rustflags = ["-C", "target-feature=-crt-static"]
```

`native/mydia_p2p/.cargo/config.toml` is the reference copy and its comment
describes the failure. A NIF is a cdylib the BEAM dlopens, and on musl the default
`crt-static` feature forbids producing a cdylib at all, so `mix compile` dies
with:

```
error: cannot produce cdylib for `<crate> v0.1.0` as the target
x86_64-unknown-linux-musl does not support these crate types
```

Hit on 2026-08-27. `native/mydia_subsync`, the subtitle re-sync NIF, shipped in
#588 without this file and broke `CI / Docker` and `CI / Player E2E` on master.
Fixed in #589 by copying the p2p crate's config verbatim.

The trap is that no pre-merge gate is musl. All of these passed on the broken
commit: the full Elixir suite locally and in CI, `cargo test`, `clippy` and `fmt`
for the crate including a CI job added in that same PR, and
`nix build .#checks.x86_64-linux.package` run locally to completion, which
produced a working `.so`. Nix and devenv are glibc. musl is exercised only by the
two Docker image builds, and `CI / Docker` does not run on pull requests, so the
first musl compile of a new crate happens on master after merge.

Copy the config into a new crate as part of the same commit that creates its
`Cargo.toml`. Do not rely on review or CI to catch its absence. The nix
`postConfigure` in `nix/packages/flake-module.nix` overwrites this file with
vendoring config, which is harmless because nix builds glibc, where neither block
applies.

## The Host API blocks; wrap call sites in spawn_blocking

`native/mydia_p2p_core`'s `Host` public API owns its own Tokio runtime and uses
`cmd_tx.blocking_send` plus `rx.blocking_recv` internally on most methods: `dial`,
`get_node_addr`, `send_response`, `get_network_stats`, `send_hls_header`,
`send_hls_chunk`, `finish_hls_stream` and `stream_file_range`. Calling these
directly from an async resolver risks tokio scheduler deadlock or thread-pool
starvation.

Wrap every blocking `Host` method call site in `tokio::task::spawn_blocking`, and
size `tokio::runtime::Builder`'s `worker_threads` and `max_blocking_threads`
accordingly at app boot.

Validated under load during U29 integration on 2026-05-23: 50 concurrent blocking
ops on a 2-worker tokio runtime completed in about 500ms across the full
pairing, HLS and GraphQL request-path test deck (16 unit and 7 integration tests),
with no deadlock or thread-pool starvation.

The deferred `Host::new_with_handle(&tokio::runtime::Handle)` companion API does
not need to be a hard prerequisite; the `spawn_blocking` discipline is sufficient
for request-path workloads. Sustained-throughput workloads with long-lived QUIC
stream sinks might benefit from sharing the app runtime. If blocking-thread
exhaustion shows up under sustained streaming load, that is the trigger to
promote `Host::new_with_handle`.

## send_request never dials, so player-to-player casting cannot work

`handle_send_request` (`native/mydia_p2p_core/src/lib.rs`, around line 1558) looks
the peer up in `connected_peers` and returns `Err("Not connected to peer: <id>")`
when it is absent. It never dials. Only `Command::Dial` into `handle_dial` calls
`endpoint.connect(...)`.

Every `P2pService.dial` and `ensureConnected` call site in the player targets the
server: `player/lib/core/channels/pairing_service.dart:214,317` and
`player/lib/core/graphql/p2p_link.dart:186`. Nothing dials another player.

So `MydiaCastBackend._probe` (`player/lib/core/cast/mydia_cast_backend.dart`)
sends `Hello` to a bare node ID read out of `RemoteRoster`, the Rust side fails
instantly with "not connected", `_probe` swallows it and returns null, and a
second player can never appear in the cast picker. Casting to another player is
non-functional in general, not only in CI. The 3-second `probeBudget` is a red
herring, since no budget helps a call that never dials.

This is what makes the `remote_control one player drives another end to end` E2E
(`player/integration_test/remote_control_test.dart`) fail at step 3. Do not
re-diagnose it as a CI discovery or timing flake. The guesses in PR #527's body
("probe budget too short in CI", "`RemoteRoster.allows()` refusing A") are both
wrong; `allows()` self-heals, triggering one throttled refetch for an unknown peer
before it refuses.

There is a Dart-side twin. `P2pService._normalizePeerForRequest`, given a bare
node ID, only calls `_waitForConnectedPeer` (a 10s poll) and never dials either.
It dials only when handed a full EndpointAddr JSON.

Fixing this means making `send_request` connect on demand. Careful:
`handle_command` awaits inline in the host event loop, so a dial there would stall
every other command while an unreachable peer times out.

## E2E pairing breaks typed codes on older players, by design

PR #513 (merged 2026-08-20) moved claim-code generation from the relay into the
server and seals the payload so the relay can read neither the code nor the node
address. Relay support shipped in metadata-relay v0.13.0, tagged and deployed the
same day.

Typed codes fail on players older than #513. The old client only knows
`GET /pairing/claim/:code` (v1), an updated server writes only v2 sealed blobs, so
that lookup 404s and the user sees "Invalid or expired claim code". The PR
documents this under its own Compatibility heading, and it is not a regression to
chase.

QR pairing is unaffected and is the workaround. The QR payload generator in
`pairing_components.ex` is byte-identical before and after
(`{instance_id, node_addr, claim_code}`), `pairWithQrData` dials `node_addr`
straight over p2p and never calls the relay, and the p2p `PairingRequest` shape is
unchanged. The gap is devices with no camera, meaning desktop players. No Android
TV target exists yet, so that case is not live.

The reverse direction is fine: a newer player tries v2 and falls back to v1 on
404, so new player with old server works. That fallback is meant to come out one
minor after #513.

The visible code format did not change, despite how the diff reads. It has been 6
plain characters all along. The old flow got the code from the relay's
`generate_code(length \\ 6)` over alphabet
`ABCDEFGHJKMNPQRSTUVWXYZ23456789`, and the new server-side generator uses that
exact length and alphabet on purpose. The `@code_length 8` and `"ABCD-1234"` dash
formatting deleted from `pairing_claim.ex` were dead code, since `generate_code/0`
was only reachable through `put_code/1` from `changeset/2` while creation went
through `changeset_with_code/2` with the relay's code. Do not restore the 8-char
format. The one real change inside the generator is rejection sampling replacing
`rem(byte, 31)`, which removes a bias toward the first eight letters.

When relay registration fails, `relay_registered: false` makes the UI hide the
code entirely and show a `#pairing-relay-warning` box reading "Typed code
unavailable", so a server on master against a pre-0.13.0 relay offers QR only.
