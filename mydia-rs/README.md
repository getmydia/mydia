# mydia-rs

A parallel Rust reimplementation of the mydia Phoenix backend, developed alongside the Elixir code in the same repository.

The binary today boots a tokio runtime, loads configuration, opens the database, runs the `schema_migrations` probe, acquires the boot-time mutual-exclusion lock (U34), and serves an axum + Dioxus SSR + wasm-hydration UI (U22 scaffolding). Background workers (U17), GraphQL (U8-U14), HLS streaming (U19), and the rest land incrementally.

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

## Dev loop

Driven by `dx serve` under devenv's process-compose. dx 0.7 owns the full dual-target build (server binary + wasm bundle), the tailwindcss watcher, the dev WebSocket for RSX hot-reload, and the asset pipeline. Nothing in the dev path runs in Docker — file watching uses real inotify, the incremental compile cache lives on the host, and signals propagate cleanly.

`dx serve --hot-patch` (Subsecond Rust-side patching) is intentionally off for now: dx 0.7.9 fails the workspace fullstack build with "Missing linker args for fat link" when it's enabled. RSX hot-reload doesn't depend on it; Rust-side hot-patch turns on once dx ships the fix.

Two other dx 0.7.9 papercuts worth knowing about:

1. **RSX literal edits aren't reflected in SSR responses**, only in connected wasm clients. dx pushes the patch over the dev WebSocket to clients that already hydrated, but doesn't rebuild the server binary — so a `curl /login` after an RSX-only edit still returns the previous HTML. The browser experience is live; the SSR raw HTML waits for the next non-RSX edit (or until you `touch` and modify a real Rust line). Comment in `dioxus-server-0.7.9/src/launch.rs:222`: "We don't do RSX hot-reload [on the server] since usually the client handles that once the page is loaded."
2. **Occasional EADDRINUSE on full rebuild restart**: dx kills the old server binary then immediately spawns the new one, but doesn't set `SO_REUSEADDR` on its listener. The new binary's `dioxus::serve` panics with "Address already in use", dx logs it as a failed restart, and the old binary keeps serving stale responses. Workaround: `./dev rs down && ./dev rs up`, or `kill` the orphan PID (`pgrep -f 'target/dx/mydia-rs/.*/server-'`) and save another edit to re-trigger the build. Tracked upstream — will go away once dx adopts `SO_REUSEADDR` on its dev listener.

Nix must be installed on the host. The Phoenix dev path still uses Docker; the Rust path runs natively the same way the Android player build does.

### Hot-reload

```
./dev rs up            # dx serve on host port 4002
./dev rs down          # stop everything cleanly
./dev rs shell         # enter the devenv shell (toolchain + dx)
```

What each kind of edit triggers:

- **RSX literals** (text, attributes, conditional bodies inside `rsx!{}`) → patch over the dev WebSocket, no rebuild, sub-second to browser.
- **Anything else in Rust** (function bodies, signatures, new deps, new server fns) → dx triggers parallel server + wasm rebuilds, then gracefully kill-restarts the binary. Initial cold build takes a few minutes; warm incremental rebuilds are a handful of seconds.
- **Tailwind utility classes** → tailwindcss --watch picks it up, rewrites `crates/web/assets/tailwind.built.css`, dx propagates the new bundle. No Rust rebuild.

`MYDIA_RS_DEV_SKIP_LOCK=true` is set in the dev process env so the kill-restart path doesn't trip the U34 lock's 30-second staleness window. Production must never set this — the lock is the only thing keeping two backends off the same DB.

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

Each runs inside the devenv shell, which pins `dioxus-cli 0.7.9` into `~/.cargo/bin` on first entry (nixpkgs only ships 0.7.3, which fails dx's cli↔crate version check). The shell also creates a placeholder `crates/web/assets/tailwind.built.css` if absent, so the `asset!()` macro resolves on a fresh checkout even before the first `dx serve` / `dx build` has compiled the real stylesheet.

### Dual-target binary layout

`crates/app/Cargo.toml` declares two features:

- `server` (the cargo default) builds the native axum binary with the config / DB / lock / SSR bootstrap. All server-only deps (`sqlx`, `tokio`, `axum`, `tower-http`, `mydia-rs-db`, ...) are gated behind this feature. Entry point: `dioxus::serve(closure)`, which owns the listener, the tokio runtime, and the devtools websocket. The closure runs the expensive boot sequence behind a `tokio::sync::OnceCell` so hot-patches reuse the cached state.
- `web` builds a wasm binary that calls `dioxus::launch(mydia_rs_web::app)`. The wasm tree has none of the server deps — only `dioxus` (with the `web` feature) and the wasm-compatible `mydia-rs-web` library.

Operators don't see this split: `./dev rs build` and `./dev rs run` go through `dx`, which orchestrates both compiles in parallel via its `@client` / `@server` channels. Plain `cargo` commands (`./dev rs check`, `./dev rs test`) hit the server target only.

## See also

`docs/plans/2026-05-21-001-refactor-rust-backend-full-rewrite-plan.md` for the full rewrite plan (gitignored — local only).
