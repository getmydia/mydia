# mydia-rs

mydia-rs is a Rust reimplementation of the mydia Phoenix backend. It ships alongside the Elixir code from the same repository and runs against the same database, the same on-disk media, and the same metadata-relay companion service. You pick which backend you run by choosing a Docker tag.

This is the binary the project is migrating toward. It is also the binary a self-hoster who wants to try the rewrite today can pull and run. Phoenix keeps shipping unchanged through the parallel window. Cutover (when it happens) is a documentation change, not a binary swap.

## Run it

```yaml
# compose.yml
services:
  mydia:
    image: ghcr.io/getmydia/mydia/mydia-rs:latest
    restart: unless-stopped
    ports:
      - "4001:4001"
    environment:
      MYDIA_CONFIG: /etc/mydia/mydia.toml
      MYDIA_DATABASE__TYPE: sqlite
      MYDIA_DATABASE__PATH: /var/lib/mydia/mydia.db
      # Keep your existing OIDC_* names here if you use OIDC. mydia-rs
      # reads them under the same names Phoenix does.
      # OIDC_ISSUER: https://auth.example.com
      # OIDC_CLIENT_ID: mydia-client
      # OIDC_CLIENT_SECRET: change-me
      # OIDC_REDIRECT_URI: https://m.example.com/auth/oidc/callback
    volumes:
      - ./mydia-data:/var/lib/mydia
      - ./mydia-config:/etc/mydia
      - /path/to/media:/media:ro
```

A fuller example with the Postgres profile lives at [`mydia-rs/compose.example.yml`](compose.example.yml).

The same image runs against both SQLite and Postgres. `MYDIA_DATABASE__TYPE` (or `database.type` in `mydia.toml`) picks the engine at runtime; both sqlx drivers are compiled into the binary. There is no `mydia/mydia-rs:latest-pg` tag, that split only exists on the Phoenix image because Ecto's adapter is linked into the BEAM release.

Environment variables and volumes carry over from a Phoenix deployment unchanged. Point mydia-rs at the same data directory, the same media mounts, and the same `OIDC_*` block, and it will boot against the existing database.

## What's the same as Phoenix

- **Database schema and data**. mydia-rs reads and writes the same tables Phoenix's Ecto migrations produced. It never writes a migration.
- **GraphQL contract** at `/api/graphql` and `/api/graphql/ws`. The Flutter player and any other GraphQL client work against mydia-rs unchanged.
- **REST API surface** under `/api/v1/*` and `/api/player/v1/*`. Paired remote devices and the player's HTTP endpoints carry over.
- **On-disk media**. Library paths, NFO files, posters, generated thumbnails, and HLS temp dirs all live where Phoenix put them.
- **metadata-relay**. Same companion service, same base URL, same protocol.
- **Bcrypt and Argon2 hashes**. User passwords and API keys verify against the existing rows.
- **JWT signing key**. The same `guardian_secret_key` (or `secret_key_base`) signs media tokens, so tokens issued by Phoenix verify against mydia-rs and the other way around during the parallel window.
- **`OIDC_*` env vars**. mydia-rs reads the same names Phoenix does. OIDC issuers do not need to be re-registered.

## What's different

- **Forced re-login at cutover.** mydia-rs uses a server-side session store (`mydia_rs_sessions` table) and a separate cookie name (`mydia_rs_session`) so it cannot share Phoenix's signed-cookie sessions. Everyone logs in once when they first hit mydia-rs. API keys, paired devices, and media tokens all survive.
- **Mutual-exclusion lock at boot.** mydia-rs refuses to start if another instance is already running against the same database. Postgres uses `pg_try_advisory_lock`; SQLite uses a `mydia_runtime_lock` row that mydia-rs creates on first boot. Phoenix is not yet aware of this lock, so during the parallel window the guard is one-way.
- **Phoenix retains migration ownership.** mydia-rs probes `schema_migrations` at startup and refuses to boot if the database is older than what the binary was built against (boot Phoenix once to apply the pending migrations). It logs a warning and continues if the database is newer than its build-time expectation.
- **Some pages out of scope.** Music, books, and adult libraries are intentionally dropped from the web UI. In-browser playback is removed, the Flutter player is the playback surface. The library import three-step flow at `/import` is a placeholder. The Quality Profiles admin page is read-only.
- **Some REST endpoints return 501.** HLS session lifecycle, download orchestration, indexer test/refresh, download-client test, and single-track subtitle extraction return `501 Not Implemented` with a `TODO` marker pending the backing crate work. Byte-range streaming, thumbnails, the config endpoint, the player's range fetch, and the indexer + download-client list paths all serve real responses.

If any of those gaps matter for your setup, keep Phoenix running until the gap closes. Cutover to mydia-rs is the operator's call.

## Operator docs

- [Cutting over from Phoenix to mydia-rs](../docs/operators/cutover-to-mydia-rs.md)
- [Rolling back from mydia-rs to Phoenix](../docs/operators/rollback-to-phoenix.md)
- [Known gotchas](../docs/operators/mydia-rs-known-gotchas.md) (inotify, session reset, OIDC, mutual-exclusion lock, schema drift)
- [Two-backend architecture](../docs/development/architecture.md)

## Layout

- `crates/app` binary that ties the domain crates together; owns the boot sequence and the runtime mutual-exclusion lock
- `crates/config` figment-based TOML + env loader, tracing setup
- `crates/db` sqlx-backed dual SQLite/Postgres pool, dialect helpers mirroring `Mydia.DB`, sqlx::Type impls matching Ecto's on-disk format
- `crates/models` Ecto-equivalent Rust structs (first batch shipped; see `crates/models/src/conventions.md`)
- `crates/auth` bcrypt/Argon2 verification, role hierarchy, media-token JWT cache, tower-sessions session store
- `crates/web` Dioxus 0.7 full-stack UI surface (layout, core components, pages, REST API handlers, security-header constants, OIDC handler). Compiles for both wasm (hydration client) and native (SSR server).
- `crates/graphql` async-graphql 7.x schema, resolvers, subscriptions
- `crates/jobs` apalis 0.7 workers (24 of them) plus cron schedule
- `crates/pubsub` `tokio::sync::broadcast` topic registry shared by GraphQL subscriptions and Dioxus server functions
- `crates/library` scanner, parser, file analysis
- `crates/downloads` client adapters, transcoding hooks, release blacklist
- `crates/indexers` Cardigann engine port and adapter registry
- `crates/metadata` provider trait, metadata-relay client, registry
- `crates/streaming` HLS session lifecycle, FFmpeg transcoder + remuxer
- `crates/subtitles` provider trait and adapters
- `crates/p2p` direct integration with `native/mydia_p2p_core` (pairing, claim, media-token issuance, GraphQL + HLS dispatch over p2p)
- `crates/events` Events context port
- `crates/integrations` Trakt + media-server clients, import-list providers, crash reporter
- `crates/parity-harness` GraphQL capture-and-replay tool
- `bin/mydia-rs-cli` clap-based user-management CLI (analog of `mix mydia.user`)

The shared p2p networking core lives at `native/mydia_p2p_core` (top of the repo) and is consumed as a Cargo path dependency from `crates/p2p`. The same crate also backs Phoenix (via Rustler) and the Flutter player (via flutter_rust_bridge).

## Dev loop

Driven by `dx serve` under devenv's process-compose. dx 0.7 owns the full dual-target build (server binary + wasm bundle), the tailwindcss watcher, the dev WebSocket for RSX hot-reload, and the asset pipeline. Nothing in the dev path runs in Docker, file watching uses real inotify, the incremental compile cache lives on the host, and signals propagate cleanly.

`dx serve --hot-patch` (Subsecond Rust-side patching) is intentionally off for now: dx 0.7.9 fails the workspace fullstack build with "Missing linker args for fat link" when it's enabled. RSX hot-reload doesn't depend on it; Rust-side hot-patch turns on once dx ships the fix.

Two other dx 0.7.9 papercuts worth knowing about:

1. **RSX literal edits aren't reflected in SSR responses**, only in connected wasm clients. dx pushes the patch over the dev WebSocket to clients that already hydrated, but doesn't rebuild the server binary, so a `curl /login` after an RSX-only edit still returns the previous HTML. The browser experience is live; the SSR raw HTML waits for the next non-RSX edit (or until you `touch` and modify a real Rust line). Comment in `dioxus-server-0.7.9/src/launch.rs:222`: "We don't do RSX hot-reload [on the server] since usually the client handles that once the page is loaded."
2. **Occasional EADDRINUSE on full rebuild restart**: dx kills the old server binary then immediately spawns the new one, but doesn't set `SO_REUSEADDR` on its listener. The new binary's `dioxus::serve` panics with "Address already in use", dx logs it as a failed restart, and the old binary keeps serving stale responses. Workaround: `./dev rs down && ./dev rs up`, or `kill` the orphan PID (`pgrep -f 'target/dx/mydia-rs/.*/server-'`) and save another edit to re-trigger the build. Tracked upstream, will go away once dx adopts `SO_REUSEADDR` on its dev listener.

Nix must be installed on the host. The Phoenix dev path still uses Docker; the Rust path runs natively the same way the Android player build does.

### Hot-reload

```
./dev rs up            # dx serve on host port 4002
./dev rs down          # stop everything cleanly
./dev rs shell         # enter the devenv shell (toolchain + dx)
```

What each kind of edit triggers:

- **RSX literals** (text, attributes, conditional bodies inside `rsx!{}`) -> patch over the dev WebSocket, no rebuild, sub-second to browser.
- **Anything else in Rust** (function bodies, signatures, new deps, new server fns) -> dx triggers parallel server + wasm rebuilds, then gracefully kill-restarts the binary. Initial cold build takes a few minutes; warm incremental rebuilds are a handful of seconds.
- **Tailwind utility classes** -> tailwindcss --watch picks it up, rewrites `crates/web/assets/tailwind.built.css`, dx propagates the new bundle. No Rust rebuild.

`MYDIA_RS_DEV_SKIP_LOCK=true` is set in the dev process env so the kill-restart path doesn't trip the U34 lock's 30-second staleness window. Production must never set this, the lock is the only thing keeping two backends off the same DB.

### One-shot commands

```
./dev rs build         # dx build of server + wasm + tailwind
./dev rs run           # dx run (one-shot, no watcher)
./dev rs test          # cargo test
./dev rs check         # cargo check
./dev rs fmt           # cargo fmt
./dev rs clippy        # cargo clippy
./dev rs sqlx-prepare  # refresh sqlx offline query cache
```

Each runs inside the devenv shell, which pins `dioxus-cli 0.7.9` into `~/.cargo/bin` on first entry (nixpkgs only ships 0.7.3, which fails dx's cli vs crate version check). The shell also creates a placeholder `crates/web/assets/tailwind.built.css` if absent, so the `asset!()` macro resolves on a fresh checkout even before the first `dx serve` / `dx build` has compiled the real stylesheet.

### Editing SQL queries

`crates/db` exposes two tiers (see `crates/db/README.md` for the policy):

- **Tier (a), portable SQL**: queries that run unchanged on both engines. Use the `sqlx::query!` / `sqlx::query_as!` macros. The Postgres arm is checked at compile time against the prepare DB and the result lands in `mydia-rs/.sqlx/`. `crates/graphql/src/repos/accounts.rs` is the reference shape.
- **Tier (b), dialect-divergent SQL**: queries that need different SQL per engine (JSON extract, datetime arithmetic, casts). Compose with the helpers in `mydia_rs_db::dialect`; the runtime `sqlx::query` / `sqlx::query_as` forms are the right tool here. No compile-time check, the integration tests are the safety net.

#### One-time setup for the prepare loop

The compile-time check needs a Postgres DB shaped like the Phoenix-owned schema. The devenv flake stands up a Postgres 16 service for this, but it boots empty and the operator populates it once with Phoenix's `mix ecto.migrate`. The mydia-rs side never writes a migration.

1. Start the devenv processes (boots Postgres on host port 5432 plus `dx serve` on 4002):

   ```bash
   ./dev rs up
   ```

   Postgres only really matters when editing a `query!` macro. Plain SQLite contributors can ignore it.

2. From the Phoenix dev container, run the migrations against the prepare DB:

   ```bash
   ./dev shell
   # inside the container:
   DATABASE_TYPE=postgres \
   DATABASE_HOST=localhost \
   DATABASE_PORT=5432 \
   DATABASE_NAME=mydia_rs_prepare \
   DATABASE_USER=postgres \
   DATABASE_PASSWORD= \
   mix ecto.migrate
   ```

   Re-run whenever a Phoenix migration changes columns or types that mydia-rs reads. The DB is on the same host as `./dev rs up` so `localhost` reaches it from inside the container's `host` network mode.

#### Day-to-day loop

```
# Edit a query somewhere under mydia-rs/crates/*/src/repos/...

./dev rs sqlx-prepare    # regenerates .sqlx/ from live Postgres
git add mydia-rs/.sqlx/  # commit the cache alongside the code change
```

The cache lives in the workspace root (`mydia-rs/.sqlx/`). CI runs `SQLX_OFFLINE=true cargo check --workspace --all-targets` so a stale cache fails the build (any `query!` macro without a matching cache entry fails to compile), which keeps the offline cache in sync with the source tree without needing a live Postgres in CI.

If you're working without the Postgres service (no edits to compile-checked queries), `SQLX_OFFLINE=true cargo check` reads the committed cache and skips the live DB.

#### Audit context

A late-2026 audit identified ~322 runtime `sqlx::query*` calls and 0 compile-time-checked queries. Schema drift had landed twice already (e.g. `downloads.status` removed months before the Rust code stopped querying it). The conversion sweep is incremental: portable-SQL call sites become tier (a) on touch, dialect-divergent ones stay tier (b). The workspace clippy lint (`disallowed_methods` in `mydia-rs/clippy.toml`) is configured but kept at `allow` by default; converted modules opt in with `#![warn(clippy::disallowed_methods)]` so the lint surfaces backsliding without escalating to a workspace-wide block on the unconverted majority.

### Binary layout

`crates/app/src/main.rs` builds a single native axum binary with `#[tokio::main]`. It boots the DB, OIDC, p2p, streaming, and download subsystems, then serves the React SPA (embedded via `mydia-rs-web-spa`), GraphQL at `/api/graphql`, and REST at `/api/v1/*` and `/api/player/v1/*` — all on one port.
