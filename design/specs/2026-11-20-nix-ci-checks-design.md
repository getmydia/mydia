# Nix-native CI: checks as derivations

Status: implemented (PR #1464). Approved in conversation 2026-11-20.

## Goal

Make CI caching predictable and job dependencies deterministic by expressing
every Linux lint, test and build as a Nix derivation. A check re-runs exactly
when one of its inputs changes, as computed by Nix, and an unchanged check is a
binary-cache hit that starts no runner at all.

What this replaces:

- `dorny/paths-filter` allowlists in `ci.yml`, `ci-relay.yml` and `ci-server.yml`.
  Today a path missing from an allowlist makes CI skip the job and go green.
- Every hand-keyed `actions/cache` family in `.github/actions/setup-devenv`
  (`mix-archives-v1`, `deps-v2-devenv`, `build-v2-devenv[-postgres]`,
  `cargo-v2`, the PLT cache) and the rules around them: save on push only,
  the `pr-<number>` fallback save, the `Cache prune` job, the cargo-cache gate.
- `needs:` chains that only exist to share a `_build` through the Actions cache.

## Scope

Phase 1 (one PR): `ci.yml`, `ci-server.yml`, `ci-relay.yml`, `ci-nix.yml`,
plus the niks3 cache on can-1.

Phase 2 (one PR): `ci-player.yml`'s Linux, web and Android jobs and
`ci-player-e2e.yml`. Flutter pub deps and cargokit inside the sandbox are the
riskiest part, so they are isolated in their own PR.

Out of scope: Apple and Windows player builds, `release.yml`, `deploy-*`,
`ci-docker.yml` (push-only, Dockerfile-based; its BuildKit registry cache
already works). These can consume Nix outputs later.

## Binary cache: niks3 on can-1

[niks3](https://github.com/Mic92/niks3) is a write coordinator, not a cache.
Clients ask it for presigned URLs, upload NARs straight to object storage and
commit the closure; the server records references in PostgreSQL for GC. Reads
never touch the server.

- **Storage:** Cloudflare R2 bucket `mydia-nix-cache` in the existing account,
  served publicly at `https://cache.mydia.dev` (R2 custom domain). R2 has no
  egress fees, and anonymous reads let fork PRs substitute.
- **Server:** `niks3.mydia.dev` on the can-1 k3s cluster, namespace
  `nix-cache`, with a small PostgreSQL StatefulSet beside it. Manifests live in
  `infra/kubernetes/apps/nix-cache/`, applied the way the other apps are.
  The DNS record must be grey-cloud (unproxied): a proxied record serves GitHub
  runners a managed challenge and silently breaks pushes.
- **Auth:** GitHub OIDC only. Audience `https://niks3.mydia.dev`, bound to
  `repository_owner = getmydia` and subject `repo:getmydia/mydia:*`. Jobs need
  `id-token: write`. Fork PRs get no OIDC token for this repo's audience, so
  they read but never write. No long-lived secret is stored in GitHub.
- **Signing:** a niks3 signing key; its public half is added to
  `extra-trusted-public-keys` in the CI Nix config.
- **GC:** `olderThan = 336h` (14 days). Master pushes `--pin master-<check>`
  for the check outputs and their build inputs, so the newest master closure
  never ages out and a PR always has a warm base.
- **Failure mode:** if can-1 is down, pushes fail and CI keeps working from
  whatever is already in R2 (reads go to R2 directly). The push step retries,
  then warns rather than failing the job, because a missed push only costs a
  rebuild later; correctness never depends on it.
- **Cachix:** stays as a read-only substituter for `devenv` (developer
  shells). CI stops pushing to the `mydia` Cachix cache.

## Derivation graph

All derivations live under `nix/ci/` and are exposed as
`checks.x86_64-linux.<name>`. Every `src` is a `lib.fileset` naming exactly
what that derivation reads. A file left out is absent in the sandbox, so the
build fails loudly instead of the job skipping.

Shared inputs (not checks themselves, but cached):

| Derivation | Inputs | Output |
| --- | --- | --- |
| `mix-deps-test` | `mix.exs`, `mix.lock`, `patches/` | fixed-output fetch of `deps/` for `MIX_ENV=test` (patched) |
| `mix-deps-compiled-{sqlite,postgres}` | the above, `config/` compile-time files | `deps/` + `_build/test/lib/<dep>` for deps only |
| `nif-mydia-p2p`, `nif-mydia-subsync` | crate dirs, `native/mydia_p2p_core`, `rust-toolchain.toml` | `.so` (crane; cargo deps are their own derivation) |
| `plugin-wasm-<name>` | `plugins/<name>`, plugin SDK crates | `.wasm` |
| `assets` | `assets/`, `package-lock.json` | built JS/CSS |
| `mydia-test-build-{sqlite,postgres}` | compiled deps, NIFs, wasm, `lib/`, `config/`, `priv/` (minus generated), `test/support` | `_build/test` with `MYDIA_PREBUILT_NIFS=1` / `MYDIA_PREBUILT_PLUGINS=1` |
| `dialyzer-plt` | compiled deps, `.elixir-version`, `.otp-version` | PLT files |

Checks:

| Check | Depends on | Replaces |
| --- | --- | --- |
| `elixir-format` | sources only | Lint: `mix format --check-formatted` |
| `elixir-lint` | `mydia-test-build-sqlite` | Lint: warnings-as-errors compile, Credo, guard greps, gettext up-to-date, `deps.unlock --check-unused` |
| `dialyzer` | `mydia-test-build-sqlite`, `dialyzer-plt` | Dialyzer job |
| `test-sqlite-{1..4}` | `mydia-test-build-sqlite`, `test/` | `Test (SQLite N/4)` |
| `test-postgres-{1..3}` | `mydia-test-build-postgres`, `test/` | `Test / PostgreSQL (N/3)` |
| `rust-native` | crate sources | Rust job: `check-rust.sh` fmt + clippy + tests |
| `rust-plugins` | plugin sources | Rust job: `check-plugins.sh` |
| `server` | `server/` | `ci-server.yml` |
| `relay-test` | `metadata-relay/` | `ci-relay.yml` test job |
| `guards` | the files each guard reads | `Guards` job (non-Nix greps move in as one check) |
| `nixos-module[-postgres]` | `packages.default` / `.postgres` | unchanged, but now cached rather than PR-gated on `flake.lock` |

Three things stay ordinary jobs in phase 1, because their input is not a
file set:

- `Lint / Ratchet` (`mix mydia.ratchet --from-git-merge-base origin/master`)
  reads git history. It substitutes `mydia-test-build-sqlite` for a warm
  `_build` and runs in `devShells.ci`. The advisory `mix_unused` report moves
  here too, still master-push only.
- `ci-nix.yml`'s `Check / Repo Contracts` and `Check / Pins & Freshness` call
  GitHub APIs and compare against upstream versions. They are already cheap
  and cache-free.
- `Test / E2E Browser (run)` keeps its devenv job until phase 2, which moves
  the browser tests with the player E2E.

The `translations` fast path is removed. `Gettext` compiles `.po` catalogs
into the backend module, so a `.po`-only PR genuinely changes the test build,
and under this design it runs the app compile and every Elixir shard (Rust,
server, relay and the PLT are still hits). The old fast path skipped those on
the assumption that catalogs cannot break anything else, which is exactly the
kind of hand-written rule this design removes. If Weblate PRs become painful,
the follow-up is to make catalogs a runtime input in test, not to bring back a
filter.

### Sandbox details

- **PostgreSQL:** the postgres shards start `postgresql` in `preCheck` on a
  unix socket under `$TMPDIR`, `initdb` per shard, then run
  `mix test --partitions 3`. The existing `config/runtime.exs` partition naming
  already isolates databases.
- **SQLite:** `max_cases: 1` is unchanged; each shard is its own derivation so
  `MIX_TEST_PARTITION` is per-sandbox.
- **No network:** tests that reach the network or rely on a writable real
  `$HOME` fail. Bypass and other loopback servers work. Fixing offenders is part
  of Phase 1; any test that genuinely needs the network is tagged and excluded
  from the sandboxed run, with the tag listed in `test/README.md`.
- **Determinism:** `ExUnit` seed is fixed per derivation (`--seed 0`) so a
  rebuild of the same inputs runs the same order. Randomized ordering is kept
  in local runs.
- **Output:** each check writes its test log and a JUnit file to `$out`, so a
  cached result still has a readable log.

### Known costs

1. Any change under `lib/`, `config/` or `priv/` recompiles the app in the
   sandbox (no incremental `_build`), measured at 3 to 4 minutes, once per
   variant. Shards, lint and Dialyzer then reuse it. A small Elixir-only PR is
   slower than today's warm path; every other PR is faster or a full cache hit.
2. A flaky test that passes once is cached as passed and is not retried on
   re-run of unchanged code. A failing build is never cached.
3. A `test/` change re-runs every shard of that variant, since `--partitions`
   assigns files round-robin and a shard's input set is the whole `test/` tree.

## Workflow shape

`ci.yml` becomes the single Nix CI workflow for phase 1 (`ci-server.yml`,
`ci-relay.yml` and the check jobs of `ci-nix.yml` fold into it; `ci-relay.yml`'s
Docker publish stays where it is).

1. **`plan`** (ubuntu, Nix installed): runs
   `nix-eval-jobs --flake .#checks.x86_64-linux --check-cache-status` against
   the substituters and emits a JSON matrix of uncached check attributes.
2. **`build`** (matrix over `plan`'s output, `fail-fast: false`): `nix build`
   one check, then `niks3 push` its closure (OIDC). Large checks (test builds)
   run as their own matrix entries; dependents substitute them, so the matrix is
   ordered in two waves: `wave: inputs` (shared derivations that two or more
   uncached checks depend on) and `wave: checks`.
3. **Aggregators:** `Test`, `Test / PostgreSQL` and `Test / E2E Browser` keep
   their names (required by the Master ruleset), `if: always()`, and pass when
   every relevant check is either cached-success or built successfully. The
   existing yq guard in Guards keeps enforcing that shape.

A PR that changes nothing the checks read finishes in the time it takes to
evaluate the flake (target under 2 minutes).

`setup-devenv` survives only for jobs outside this scope. The `Cache prune`
job and all `actions/cache` steps in the migrated workflows are removed.

## Rollout

1. Deploy niks3 + R2 + DNS on can-1, verify a manual push and an anonymous
   substitute.
2. Land Phase 1 with the new workflow running alongside the old jobs, old jobs
   still required, for at least a few PRs; compare results and timings.
3. Move the required check names onto the new aggregators, delete the old jobs,
   `setup-devenv` cache steps and `Cache prune`.
4. Update `.github/ci.md`: replace the path-gate, cache-key and `_build`
   sections with the derivation graph and the niks3 operations notes.

## Success criteria

- A PR touching only docs or the player runs no Nix check work in the
  `Nix / Checks` verdict: every such check is a cache hit, so no check job
  starts. The jobs that are not derivations
  (`Lint / Ratchet`, `Rust / SMB integration`, `Test / E2E Browser`) still
  run on every PR, by design: there are no path filters to skip them. So
  do the non-blocking NixOS module VM tests, whose package takes the whole
  repository as source (`nix/ci/README.md`, "The derivation graph").
- No `hashFiles`, `actions/cache` or `paths-filter` remain in migrated
  workflows.
- Warm-path wall clock for an Elixir PR is no worse than today's ~8 minutes
  median; a full hit is under 2 minutes.
- Actions cache usage for the migrated workflows drops to zero.
