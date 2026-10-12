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
`wasi:http` and `wasi:sockets` removed, debug sections stripped, 39 MB) is the
artifact; `out/cardigann-raw.wasm` is an intermediate.

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
  install that picks Prowlarr's engine (`CARDIGANN_ENGINE=prowlarr` or the
  Indexers page) downloads
  `cardigann-<hash>.wasm` on first boot into `cardigann/` under
  `MYDIA_DATA_DIR`, or next to the database file when that is unset (`/config`
  in the image) (`Mydia.Indexers.Cardigann.Wasm.Delivery`). It checks the file
  against the pinned SHA-256, compiles it once and caches the result as
  `cardigann-<wasm sha256>-wasmtime<version>-<arch>.cwasm` beside it, with a
  `.sha256` of its own that is checked before every load. A failed download or
  compile is retried in the background (30 s, doubling, up to 30 min).
  `CARDIGANN_WASM_PATH` points at a local copy for air-gapped installs; that
  file is verified against the same pin.
- A dev `mix compile` with `CARDIGANN_ENGINE=prowlarr` set runs
  `mix mydia.cardigann_guest fetch` (the `:cardigann_guest` compiler; skipped in
  every other env, when the engine is not selected, and with
  `MYDIA_SKIP_CARDIGANN_FETCH=1`). CI runs `fetch` explicitly. This is the
  development and CI path:
  `fetch` downloads the asset into `priv/cardigann/`, or, when none is
  published, copies `out/cardigann.wasm` from a local build. With neither it
  warns and carries on; Cardigann wasm then reports unavailable.
- The cached `.cwasm` and the memory saving need the patched Wasmex
  (`patches/wasmex`, applied by `mix deps.patch`) built from source with
  `WASMEX_BUILD=1`: the Dockerfile and the Nix package do. Without it the
  engine still works, compiling in memory on every start and keeping the
  compiler's heap.

## The pin

A release verifies the guest it downloads against a SHA-256 known at build
time, from the first of:

1. `ARTIFACT_SHA256`, `<source-hash> <sha256>` on one line, when its hash is the
   current source hash. The Nix package has only this.
2. The `.sha256` sidecar of the published asset, which the Docker build fetches
   (`mix mydia.cardigann_guest pin`; only the 64-character sidecar, never the
   guest) into `priv/cardigann/`.

With neither, the engine reports "no published Cardigann engine for this
build". The guest is published after a master push, so a build of a commit that
changes it can have no sidecar yet: that is soft for PR and CI image builds and
fatal for release images (`CARDIGANN_REQUIRE_PIN=true` in `release.yml`).

To pin a Nix build, after the master push has published the asset, set
`ARTIFACT_SHA256` in a follow-up commit (the pin file is not part of the source
hash) to `<mix mydia.cardigann_guest hash> <contents of the .sha256 file>`.

## Host-side behaviour that is not Prowlarr's

The guest behaves as Prowlarr does; what Mydia adds is in
`Mydia.Indexers.Cardigann.Wasm.Adapter`:

- **Mirror failover.** Prowlarr has none. A search that comes back empty with the
  guest's `request-failed` flag is repeated against the next entry of `links:`
  (the stored `active_link` first, three at most), and a mirror that answers after
  another failed is stored as `active_link`, as the Elixir engine does. Login,
  download and the connection test go to `active_link` too. The attempts share the
  search deadline, and no mirror is started with under two seconds left.
- **Failed searches are errors.** Where every mirror ended empty with the flag, the
  adapter returns the error shape the Elixir engine returns for HTTP failures
  (`search_failed`, "Server error: HTTP 503" or "HTTP 403", with
  `details.tracker_status`; `connection_failed` when no response came back), so the
  UI and health tracking treat both engines alike. The guest itself returns the
  empty page.

## CI gap: the main CI often has no wasm

The `fetch` step in `ci.yml` only finds an asset that is already published. So on
a PR that changes the guest, and on a master push that races the publish job,
the main CI runs without the wasm. Any test that needs it (the Wasmex-hosted
engine tests) must be explicitly tagged and visibly skipped when
`Artifact.load/0` fails, with the skip reason printed. It must never pass
silently, or a green check will say nothing about the engine.
