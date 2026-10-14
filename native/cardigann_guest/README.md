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
directory and, on a push to master, publishes it as its own release,
`cardigann-guest-<hash>`, holding `cardigann-<hash>.wasm` plus `.sha256`,
`.LICENSE` and `.NOTICE`. The repo has immutable releases, so the release is
built as a draft and published once every asset is on it, and a published
asset can never be replaced.

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
  against the pinned SHA-256, then loads the compiled form from, in order: the
  cached `cardigann-<wasm sha256>-wasmtime<version>-<arch>.cwasm` beside it (its
  own `.sha256` is checked before every load), the published `.cwasm` (below),
  or a local compile. Whichever of the last two succeeds writes the cache file.
  A failed download or compile is retried in the background (30 s, doubling, up
  to 30 min).
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

### The precompiled `.cwasm`

Compiling the guest takes 18 s and peaks near 1.6 GB, so CI also publishes the
compiled form. `.github/workflows/cardigann-cwasm.yml` builds it in the release
image's own builder (Dockerfile target `cwasm-out`, on a native runner per
architecture) and publishes it as its own release,
`cardigann-cwasm-<hash>-wasmtime<ver>-cfg<n>`, holding
`cardigann-<hash>-wasmtime<ver>-cfg<n>-<arch>.cwasm.gz` plus a `.sha256` of the
decompressed file. `<hash>` is the guest's source hash, `<ver>` the wasmtime
version of the Wasmex the image builds, and `<n>` the version of the engine
configuration, so a change to any of them publishes a new release and an old
image never fetches a mismatched file.

The Docker build records that checksum with `mix mydia.cardigann_guest pin
--cwasm`, which is soft: with no published `.cwasm` the build carries no pin and
the install compiles locally, as before. At first boot the engine downloads the
`.cwasm.gz`, inflates it while writing, keeps it only when its SHA-256 matches
the pin, and loads it. The `.wasm` is downloaded as well, because deserializing
a component needs the interface it was compiled from.

A failed download, a checksum mismatch, or a file wasmtime rejects (another
architecture or engine configuration) deletes the file and falls back to the
local compile, whose memory peak is the one in `BENCH.md`. Nix has no `.cwasm`
pin and always compiles locally. A pin has to come from the CI build, since the
same guest compiled on another libc gives different bytes.

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
