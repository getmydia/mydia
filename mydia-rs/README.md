# mydia-rs

A parallel Rust reimplementation of the mydia Phoenix backend, developed alongside the Elixir code in the same repository.

The binary today boots a tokio runtime, loads configuration, opens the database, runs the `schema_migrations` probe, acquires the boot-time mutual-exclusion lock, and exits. Real functionality (HTTP server, GraphQL surface, background workers, p2p, web UI) lands incrementally in subsequent units of the rewrite plan.

## Layout

- `crates/app` — binary that ties the domain crates together; owns the boot sequence and the runtime mutual-exclusion lock
- `crates/config` — figment-based TOML + env loader, tracing setup
- `crates/db` — sqlx-backed dual SQLite/Postgres pool, dialect helpers mirroring `Mydia.DB`, sqlx::Type impls matching Ecto's on-disk format
- `crates/models` — Ecto-equivalent Rust structs (first batch shipped; see `crates/models/src/conventions.md`)
- `crates/auth` — bcrypt/Argon2 verification, role hierarchy, media-token JWT cache
- `crates/{graphql, jobs, pubsub, library, downloads, indexers, metadata, streaming, subtitles, p2p, web, parity-harness}` — placeholders pending later units
- `bin/mydia-rs-cli` — clap-based user-management CLI (stub for now; the analog of `mix mydia.user`)

The shared p2p networking core (`native/mydia_p2p_core` at the repo root) is consumed as a path dependency from `crates/p2p` once that unit lands.

## Two ways to run it

The Rust workspace has two transports, both under the `./dev rs` namespace.

### Native (fast feedback loop)

`./dev rs build|run|test|check|fmt|clippy|sqlx-prepare` enter a `nix develop` shell with the Rust toolchain and run `cargo` from the `mydia-rs/` directory. No Docker round-trip; rebuilds are incremental and immediate.

Nix must be installed on the host (the Phoenix dev path uses Docker; the Rust path uses Nix the same way the Android player build does).

```
./dev rs build         # cargo build
./dev rs run           # cargo run -p mydia-rs-app
./dev rs test          # cargo test
./dev rs check         # cargo check
./dev rs fmt           # cargo fmt
./dev rs clippy        # cargo clippy
./dev rs sqlx-prepare  # refresh sqlx offline query cache
```

### Docker (long-running container, parallel to Phoenix)

`./dev rs up|down|restart|rebuild|logs|shell` wrap `docker compose -f compose.yml -f compose.mydia-rs.yml`. The container runs on host port `4002` so it sits beside the Phoenix `app` service (port `4000`) and the dev `metadata-relay` (port `4001`) without colliding.

```
./dev rs up            # bring up the container in the background
./dev rs logs -f       # tail container logs
./dev rs shell         # exec into the container
./dev rs restart       # restart after a code change + rebuild
./dev rs rebuild       # rebuild the image (slow; do this after substantive changes)
./dev rs down          # stop and remove
```

The container holds its own SQLite database under the `mydia_rs_dev_data` volume by default. Sharing Phoenix's `mydia_dev.db` is allowed (the runtime-lock guard from U34 doesn't refuse against Phoenix), but two SQLite writers against the same WAL file gets fragile under load — override `MYDIA_DATABASE__PATH` and bind-mount the file if you want to try anyway.

Until the supervision tree lands in U22+, the container boots, runs the schema and lock checks, then idles on `MYDIA_KEEP_ALIVE=true` waiting for SIGTERM. That gives `./dev rs logs -f` something useful to show while you iterate on the web UI work.

## See also

`docs/plans/2026-05-21-001-refactor-rust-backend-full-rewrite-plan.md` for the full rewrite plan (gitignored — local only).
