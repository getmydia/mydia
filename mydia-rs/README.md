# mydia-rs

A parallel Rust reimplementation of the mydia Phoenix backend, developed alongside the Elixir code in the same repository.

This is workspace scaffolding only at the moment (U1 of the rewrite plan). The binary boots a tokio runtime and exits cleanly. Real functionality lands incrementally in subsequent units.

## Layout

- `crates/app` — the axum + Dioxus binary that ties the domain crates together
- `crates/{config, db, models, auth, graphql, jobs, pubsub, library, downloads, indexers, metadata, streaming, subtitles, p2p, web, parity-harness}` — empty library crate skeletons; ports of the Phoenix subsystems will land here over time
- `bin/mydia-rs-cli` — clap-based user-management CLI (stub for now; the analog of `mix mydia.user`)

The shared p2p networking core (`native/mydia_p2p_core` at the repo root) is intended to be consumed as a path dependency from `crates/p2p` once that unit lands.

## Working with the workspace

All commands go through the `./dev` wrapper at the repo root:

```
./dev rs build         # cargo build
./dev rs run           # cargo run -p mydia-rs-app
./dev rs test          # cargo test
./dev rs check         # cargo check
./dev rs fmt           # cargo fmt
./dev rs clippy        # cargo clippy
./dev rs sqlx-prepare  # refresh sqlx offline query cache
```

`./dev rs` enters a `nix develop` shell with the Rust toolchain, so Nix needs to be installed on the host (the Phoenix dev path uses Docker; the Rust path uses Nix the same way the Android player build does).

See `docs/plans/2026-05-21-001-refactor-rust-backend-full-rewrite-plan.md` for the full rewrite plan.
