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

```text
error: cannot produce cdylib for `<crate> v0.1.0` as the target
x86_64-unknown-linux-musl does not support these crate types
```

Hit on 2026-08-27. `native/mydia_subsync`, the subtitle re-sync NIF, shipped in
PR #588 without this file and broke `CI / Docker` and `CI / Player E2E` on
master.
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

## The Docker image does not build the NIFs through Rustler

In the Docker image, cargo builds `mydia_p2p` and `mydia_subsync` in a separate
`nifs` stage and `config/prod.exs` sets `skip_compilation?` so `mix compile`
only loads the prebuilt `.so` files. A new `use Rustler` crate needs no Docker
change: it builds through Rustler in the `builder` stage as before, only more
slowly. Moving it into the `nifs` stage is optional and takes three edits made
together. See "The Docker image builds the NIFs in their own stage" in
`.github/ci.md`.

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

## Stopping a host takes an explicit shutdown

Dropping every `Host` handle ends the event loop, but on the server nothing drops
them: the NIF's listener thread keeps its own clone of the host for as long as
events arrive. `Mydia.P2p.Server.terminate/2` calls `stop_host/1`, which sends
`Command::Shutdown`; the loop closes the endpoint and only then answers, so a
restart on a fixed `P2P_BIND_PORT` never races the old socket.

`LOG_TX` belongs to the newest host. A host started after another stopped takes
the log channel over, and releasing the old sender is what closes the old
channel and ends the old listener thread.

## send_request dials on demand, and probes a stalled GraphQL connection

`Command::SendRequest` (`native/mydia_p2p_core/src/lib.rs`) uses the peer's live
connection when `connected_peers` has one. When it has none, it dials: the request
is queued on an `InFlightDial` for that node ID, and a dial already in flight, from
`Command::Dial` or an earlier request, is joined rather than duplicated. A
controller can therefore send `Hello` to a bare node ID out of `RemoteRoster`.
`handle_command` still awaits inline in the host event loop, so keep anything slow
out of that arm.

The Dart side does not lean on this for every call. `P2pService._normalizePeerForRequest`,
given a bare node ID, only calls `_waitForConnectedPeer` (a 10s poll) and never
dials; it dials only when handed a full EndpointAddr JSON.

A request that goes unanswered is handled per kind in `send_request_on`. Remote
control keeps the fixed `CONTROL_REQUEST_TIMEOUT` of 4s and closes the connection
when it expires. GraphQL can legitimately run long, so it has no deadline. Instead
the core waits `STALL_PROBE_AFTER` (1.5s), sends a `Ping` on the same connection, and
gives it `STALL_PROBE_TIMEOUT` (3s). A `Pong` means the request is merely slow: the
wait continues, and the probe repeats every `STALL_PROBE_AFTER` while the request is
pending, since a path can die after answering once. No `Pong` closes the connection
and fails the request with an error prefixed `connection_stalled:`; the closed
connection is pruned, so the next request dials a fresh one.

The first probe runs early because the commonest dead path is a startup one. A
client on the same LAN as its server switches from the relay to a direct path
within milliseconds of connecting, while its first requests are in flight. On a
Wi-Fi mesh (measured on a TP-Link Deco: a wired client behind a satellite, the
server wired to the main unit) the backhaul can drop nearly all of that flow's
packets, and iroh keeps sending on the selected path instead of falling back to
the relay. Until the probe closes the connection every request waits; at the old
6s + 3s that was a 9 second launch, and it now costs about 4.5. The probe timeout
stays at 3s because a failed probe closes the whole connection, interrupting any
media stream on it.

The Dart GraphQL transport resends a query once when it fails after reaching the
connection (`connection_stalled`, or the connection closing under it). It never retries a connect or dial failure, which a second
dial to the same address rarely fixes, and never a mutation, which may already
have run. Media streams have their own recovery and are not probed.

## Paired players read each other's files over HlsStream

Files libraries lent between paired players use two paths. The index and
manifest travel as `MydiaRequest::PeerFiles` (`PeerFilesRequest::Manifest` and
`IndexPage`, CBOR, each carrying an auth proof), answered by Dart through the
peer files channel; the server listener refuses it. File bytes never ride
that request. They use the existing `HlsStream` request with session id
`peerfile:<host account id>` and the host's file path as base64url without
padding (`PEER_FILE_SESSION_PREFIX`). Range support is the same as any other
stream.

`peer_files_host.rs` in `mydia_player_p2p` answers those reads, and it is the
security boundary:

- Only peers in the member allowlist Dart pushes in are answered; anyone else
  gets 403.
- Rust never decides which paths are readable. It asks Dart for a grant per
  `(account id, path)`. Dart grants only indexed files and their sidecars, and
  anything without a grant is 404.
- A grant is cached per `(account id, path)` so a seeking player does not ask
  Dart on every range. It is dropped when its read finds nothing readable, and
  when Dart invalidates the account (its index changed). A grant resolved
  across an invalidation is served but not cached.
- Each peer gets 4 concurrent reads (`READS_PER_PEER`). The fifth waits for a
  slot rather than failing.
- A grant request Dart does not answer in 10 seconds (`GRANT_TIMEOUT`) is a
  404.

A share the host cannot reach answers 502 and drops that account's grants;
the viewer words it differently from a host that never answered.

## Tracing the transport on a running server

The NIF's logs reach the journal only through the Elixir Logger, which drops
`debug` and `trace` and keeps just each event's message. A noq trace read that
way has lost the span context (`drive{id}:pkt{path_id}:recv{pn}`) that makes it
readable. To trace the server's QUIC traffic, set these in the server's
environment and restart it:

| Variable | Meaning |
| --- | --- |
| `MYDIA_P2P_TRACE_FILE` | Path to write full `tracing` output to. Unset, nothing changes. |
| `MYDIA_P2P_TRACE` | Filter for that file. Default `info,mydia_p2p_core=debug,iroh=debug,noq_proto=trace,noq=debug`. |
| `MYDIA_P2P_TRACE_MAX_BYTES` | Size at which the file moves to `<path>.1`. Default 512 MiB. |

`noq_proto=trace` logs every packet, so a server streaming media fills the cap in
minutes. A file that cannot rotate stops growing rather than filling the disk.
Give each process its own path: rotation counts only the writing process's bytes. The file sits beside the Elixir forwarding rather than replacing it,
and `RUST_LOG` still sets the level that forwarding uses.

To reproduce a stalled first request against a server, run the `startup_burst`
example in `native/mydia_p2p_core/examples/` (`--listen` for a stand-in server):
it dials over the relay and fires a batch of GraphQL requests the moment the
connection comes up, while iroh is still moving to a direct path.

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

## The relay list is resolved outside the core

`HostConfig.relay_urls` is a plain `Vec<String>` and the core does no I/O to
fill it. `build_relay_mode` parses the entries, drops anything unparseable, and
appends n0's three production relays underneath as fallbacks. An empty vec, or
one where nothing parsed, leaves iroh's preset alone: an empty
`RelayMode::Custom` map is invalid, because `Endpoint` requires at least one
relay.

Deciding what goes in that vec belongs to the callers, and there are two of
them with the same four precedence levels:

- `lib/mydia/p2p/relay_list.ex` for the server
- `player/lib/core/p2p/relay_list.dart` for the player

Both read `GET /client-config` from the metadata relay at boot, so a relay can
be added or moved by changing the metadata relay's configuration rather than
shipping a new server image and player build. Change one of those two files
and you almost certainly need to change the other.

## Rust rules

Every first-party crate (`server/`, `native/`, `player/rust/`, `plugins/`,
`plugins-extra/`) uses one lint set: clippy pedantic, no `dbg!` or printing, no
`unsafe` outside generated code, no `unwrap`, `expect`, `panic!`, `todo!` or
`unimplemented!` in non-test code, and a `reason` on every lint exception.

- The canonical tables live in `rust-lints.toml`. Each `Cargo.toml` carries a
  copy (`[workspace.lints]` in `server/Cargo.toml`), and
  `scripts/check-rust-lints.sh` (pre-commit and CI) fails when one drifts. A
  crate may add entries, never drop or weaken one.
- `clippy.toml` at the repo root relaxes the panic and print lints inside tests.
  It is the only clippy.toml allowed.
- An exception is local and states why:
  `#[expect(clippy::cast_possible_truncation, reason = "track index is < 64")]`.
  Prefer `#[expect]`, which errors once the lint stops firing, so stale
  exceptions surface. Use `#[allow]` only where `expect` cannot work, such as
  the generated `frb_generated` module.
- A genuine invariant may keep `expect("...")` under
  `#[expect(clippy::expect_used, reason = "...")]`. Anything a caller, the
  network or the filesystem can trigger returns an error instead.
- `clippy.toml` covers `#[test]` fns and `#[cfg(test)]` modules only. An
  integration-test crate (`tests/*.rs`, with the modules it includes) whose
  helpers sit outside `#[test]` fns takes one crate-level
  `#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, reason = "...")]`.
  That allow is for test crates only, never for production code.
- Adding a crate: copy the tables from `rust-lints.toml` into its `Cargo.toml`.
  Crates under `native/`, `player/rust/`, `plugins/` and `plugins-extra/` are
  linted automatically.

Each group has its own gate, all running clippy with `-D warnings`:

- `scripts/check-rust.sh` covers `native/*` and `player/rust/*` with
  `--all-targets --all-features`. The p2p core also gets a wasm32 clippy step in CI.
- `scripts/check-plugins.sh` covers the plugins against `wasm32-wasip2`, test
  code included, and reports every failing crate instead of stopping at the first.
- `server/` is linted by `ci-server.yml` and its own hook.
- `scripts/test-plugins.sh` runs the plugin tests on the host, which clippy only
  type-checks.
