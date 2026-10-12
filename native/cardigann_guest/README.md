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

- The release (Docker image, Nix package) does not contain the guest. An
  install that sets `CARDIGANN_ENGINE=prowlarr` downloads
  `cardigann-<hash>.wasm` into `<data dir>/cardigann/` on first boot
  (`Mydia.Indexers.Cardigann.Wasm.Delivery`), checks it against the SHA-256 in
  `ARTIFACT_SHA256`, which the build compiles in, compiles it once and caches
  the result as `cardigann-<hash>-wasmtime<version>-<arch>.cwasm` beside it.
  `CARDIGANN_WASM_PATH` points at a local copy for air-gapped installs; that
  file is verified against the same pin.
- `mix compile` runs `mix mydia.cardigann_guest fetch` (the `:cardigann_guest`
  compiler; skipped in the test env, and with `MYDIA_SKIP_CARDIGANN_FETCH=1`,
  which the Docker and Nix builds set). It is the development and CI path:
  `fetch` downloads the asset into `priv/cardigann/`, or, when none is
  published, copies `out/cardigann.wasm` from a local build. With neither it
  warns and carries on; Cardigann wasm then reports unavailable.
- The cached `.cwasm` and the memory saving need the patched Wasmex
  (`patches/wasmex`, applied by `mix deps.patch`) built from source with
  `WASMEX_BUILD=1`: the Dockerfile and the Nix package do. Without it the
  engine still works, compiling in memory on every start and keeping the
  compiler's heap.

## Updating the pin

`ARTIFACT_SHA256` holds `<source-hash> <sha256>` on one line. It is the only
place the checksum is copied: a release cannot verify a download without it.
Any other content (it ships as `unpublished`), or a hash that is not the
current source hash, means the build has no pin, and the engine then reports
that it cannot download or verify the guest.

A PR that changes the guest therefore takes two steps:

1. Merge it. The master push publishes `cardigann-<hash>.wasm`; the Publish
   step prints the `.sha256`.
2. In a follow-up commit, set `ARTIFACT_SHA256` to
   `<mix mydia.cardigann_guest hash> <contents of the .sha256 file>`.

Until step 2 lands, builds from master ship without a usable pin.

## CI gap: the main CI often has no wasm

The `fetch` step in `ci.yml` only finds an asset that is already published. So on
a PR that changes the guest, and on a master push that races the publish job,
the main CI runs without the wasm. Any test that needs it (the Wasmex-hosted
engine tests) must be explicitly tagged and visibly skipped when
`Artifact.load/0` fails, with the skip reason printed. It must never pass
silently, or a green check will say nothing about the engine.
