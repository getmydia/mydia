# mydia-rs

A parallel Rust reimplementation of the mydia Phoenix backend, developed alongside the Elixir code in the same repository.

The binary today boots a tokio runtime, loads configuration, opens the database, runs the `schema_migrations` probe, acquires the boot-time mutual-exclusion lock (U34), and serves an axum + Dioxus SSR home page (U22 scaffolding). Background workers (U17), GraphQL (U8-U14), HLS streaming (U19), and the rest land incrementally.

## Layout

- `crates/app` — binary that ties the domain crates together; owns the boot sequence and the runtime mutual-exclusion lock
- `crates/config` — figment-based TOML + env loader, tracing setup
- `crates/db` — sqlx-backed dual SQLite/Postgres pool, dialect helpers mirroring `Mydia.DB`, sqlx::Type impls matching Ecto's on-disk format
- `crates/models` — Ecto-equivalent Rust structs (first batch shipped; see `crates/models/src/conventions.md`)
- `crates/auth` — bcrypt/Argon2 verification, role hierarchy, media-token JWT cache
- `crates/web` — Dioxus 0.7 full-stack UI surface (layout, core components, pages, security-header constants). Compiles for both wasm (hydration client) and native (SSR server).
- `crates/{graphql, jobs, pubsub, library, downloads, indexers, metadata, streaming, subtitles, p2p, parity-harness}` — domain layer (most landed in U8-U21, U32)
- `bin/mydia-rs-cli` — clap-based user-management CLI (stub for now; the analog of `mix mydia.user`)

The shared p2p networking core (`native/mydia_p2p_core` at the repo root) is consumed as a path dependency from `crates/p2p` once that unit lands.

## Two ways to run it

All `./dev rs` commands run natively via Nix devenv. No Docker layer for development — file watching uses real inotify, signals propagate correctly to the running binary, and `cargo build`'s incremental compile cache lives on the host filesystem so rebuilds are seconds.

Nix must be installed on the host. The Phoenix dev path still uses Docker; the Rust path runs natively the same way the Android player build does.

### Hot-reload dev loop

```
./dev rs up            # start cargo-watch + tailwindcss --watch, host port 4002
./dev rs down          # stop everything cleanly
./dev rs shell         # enter the devenv shell (toolchain + dx + tailwindcss)
```

`./dev rs up` launches a devenv-managed `process-compose` session with two processes:

- **cargo-watch** runs `cargo build -p mydia-rs-app && exec ./target/debug/mydia-rs`. On any Rust source change under `crates/` or `bin/`, the running binary gets SIGTERM, cargo rebuilds incrementally, and `exec` replaces the shell with the fresh binary so it lands in cargo-watch's own process group (signals propagate cleanly on the next restart). End-to-end edit-to-served time is around 5 seconds for a small change.
- **tailwindcss --watch** compiles `crates/web/assets/app.css` (Tailwind v4 + DaisyUI source) into `app.built.css` whenever an RSX file introduces a new utility class. The asset macro in `crates/web/src/app.rs` references `app.built.css`, so the SSR response always serves the latest stylesheet.

Two dev-only knobs make this work:

- `MYDIA_RS_DEV_SKIP_LOCK=true` — disables the U34 boot-time mutual-exclusion lock, because cargo-watch restarts faster than the lock's 30-second stale-after window. Production must never set this.
- `SO_REUSEADDR` is set on the listener (in `crates/app/src/server.rs`) so the rebuilt binary can immediately rebind port 4002 without waiting for the kernel's TIME_WAIT.

### One-shot cargo commands

```
./dev rs build         # cargo build (full workspace)
./dev rs run           # cargo run -p mydia-rs-app (no watcher)
./dev rs test          # cargo test
./dev rs check         # cargo check
./dev rs fmt           # cargo fmt
./dev rs clippy        # cargo clippy
./dev rs sqlx-prepare  # refresh sqlx offline query cache
```

Each enters a `nix develop` shell with the Rust toolchain and runs `cargo` from the `mydia-rs/` directory. Useful for CI-equivalent checks or one-off builds outside the watcher loop.

### dx (Dioxus CLI)

`dx 0.7.9` is installed into `~/.cargo/bin` by the devenv shell's `enterShell` hook (nixpkgs ships 0.7.3 which is too old for our dioxus crate dep at 0.7.9). It's available inside `./dev rs shell` for manual experimentation with the wasm asset pipeline, but `./dev rs up` doesn't use it — dx 0.7's hot-reload mechanism is RSX-patching against a connected browser client, not server rebuild, and our SSR-first use case wants the latter.

## Web UI (U22 scaffolding)

`crates/web` carries the Dioxus 0.7 full-stack UI: layout (DaisyUI drawer + sidebar), core components (button, input, modal, icon, flash), router skeleton (`/`, `/hello/:name`), and the CSP / security-header constants the server middleware reads. `crates/app/src/server.rs` mounts the Dioxus router on axum with security middleware, request-id propagation, compression, panic-catch, and trace layers.

### Dual-target binary layout

`crates/app/Cargo.toml` declares two features:

- `server` (the cargo default) builds the native axum binary with the config / DB / lock / SSR bootstrap. All server-only deps (`sqlx`, `tokio`, `axum`, `tower-http`, `mydia-rs-db`, ...) are gated behind this feature.
- `web` builds a wasm binary that calls `dioxus::launch(mydia_rs_web::app)`. The wasm tree has none of the server deps — only `dioxus` (with the `web` feature) and the wasm-compatible `mydia-rs-web` library.

Operators don't see this split: `./dev rs build` and `./dev rs run` use the default `server` feature; `dx serve` orchestrates both compiles. The split is what lets `mydia-rs-app` be a single binary crate that compiles cleanly for `wasm32-unknown-unknown` (client) and `x86_64-unknown-linux-gnu` (server).

### Known follow-up: wasm hydration + RSX hot-patching

`./dev rs up` rebuilds and restarts the server binary on every Rust edit. That's the right shape for SSR-first development but doesn't deliver Dioxus's sub-second RSX hot-patching — the wasm bundle isn't being built and served as part of the dev loop, so there's no wasm browser client to hot-patch against.

Wiring the wasm side is a separate follow-up: build the wasm target alongside the server, deliver the bundle via the asset pipeline, and have the wasm client connect to dx's hot-reload WebSocket. The dual-target crate shape is already in place (`server` / `web` features on `mydia-rs-app`); what's missing is the orchestration that builds both targets and bridges dx's RSX patches into the live browser. Once that lands, RSX-only edits will update the browser in under a second without rebuilding the server.

## See also

`docs/plans/2026-05-21-001-refactor-rust-backend-full-rewrite-plan.md` for the full rewrite plan (gitignored — local only).
