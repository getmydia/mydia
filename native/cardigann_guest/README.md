# Cardigann guest

Prowlarr's C# Cardigann engine compiled to a wasip2 component, hosted by Mydia
through Wasmex. Design notes and the spike results are in `SPIKE.md`; the
engine substitutions are in `SUBSTITUTIONS.md`.

## Building

Everything runs in Docker, so no .NET or Rust toolchain is needed on the host.

    native/cardigann_guest/build.sh test   # xunit tests on plain .NET
    native/cardigann_guest/build.sh wasm   # out/cardigann.wasm (the artifact)

A cold `wasm` build takes several minutes. Caches live in
`~/.cache/mydia-cardigann-nuget`, `~/.cache/mydia-cardigann-nuget-wasi-sdk` and
`~/.cache/mydia-cardigann-cargo`. Only `out/cardigann.wasm` (composed, with
`wasi:http` and `wasi:sockets` removed) is the artifact; `out/cardigann-raw.wasm`
is an intermediate.

## The published artifact

Nobody has to build the guest to run Mydia. CI
(`.github/workflows/cardigann-guest.yml`) builds it on every change under this
directory and, on a push to master, publishes it to the `cardigann-guest`
release as `cardigann-<hash>.wasm` plus `.sha256`, `.LICENSE` and `.NOTICE`.

`<hash>` is the first 16 hex characters of a SHA-256 over every tracked file
under `native/cardigann_guest`, as `path NUL contents` in byte-sorted path
order. Excluded: build output (`out/`, `bin/`, `obj/`, `.prowlarr/`,
`deny/target/`, `deny/gen/`), docs (`*.md`, so a doc edit never forces a rebuild)
and `ARTIFACT_SHA256`. The same value is computed by
`scripts/source-hash.sh` (CI) and
`Mydia.Indexers.Cardigann.Wasm.SourceHash` (Elixir); a test keeps them equal.
Print it with `mix mydia.cardigann_guest hash`.

Consumers:

- `mix compile` runs `mix mydia.cardigann_guest fetch` (the `:cardigann_guest`
  compiler; skipped in the test env, and with `MYDIA_SKIP_CARDIGANN_FETCH=1`).
  `fetch` downloads the asset into `priv/cardigann/`, or, when none is
  published, copies `out/cardigann.wasm` from a local build. With neither it
  warns and carries on; Cardigann wasm then reports unavailable.
- The Docker build runs `mix mydia.cardigann_guest verify --allow-missing`: a
  missing file is fine, a file with a wrong checksum fails the image.
- The Nix package fetches the asset with a fixed-output `fetchurl`, using the
  pin below.

## Updating the Nix pin

`ARTIFACT_SHA256` holds `<source-hash> <sha256>` on one line. It is the only
place the hash is copied, because Nix cannot compute it and needs the asset's
content hash for a fixed-output fetch. Any other content (it ships as
`unpublished`) makes the Nix build skip the fetch with a warning.

A PR that changes the guest therefore takes two steps:

1. Merge it. The master push publishes `cardigann-<hash>.wasm`; the Publish
   step prints the `.sha256`.
2. In a follow-up commit, set `ARTIFACT_SHA256` to
   `<mix mydia.cardigann_guest hash> <contents of the .sha256 file>`.

Until step 2 lands the Nix package builds without the guest (a stale pin names a
different file than the sources expect, which the runtime treats as missing).

## CI gap: the main CI often has no wasm

The `fetch` step in `ci.yml` only finds an asset that is already published. So on
a PR that changes the guest, and on a master push that races the publish job,
the main CI runs without the wasm. Any test that needs it (the Wasmex-hosted
engine tests) must be explicitly tagged and visibly skipped when
`Artifact.load/0` fails, with the skip reason printed. It must never pass
silently, or a green check will say nothing about the engine.
