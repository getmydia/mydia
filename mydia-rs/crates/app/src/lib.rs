//! mydia-rs app library surface.
//!
//! Exposed so the binary at `src/main.rs` and integration tests under
//! `tests/` share the same code paths. The modules below are
//! server-only — they depend on sqlx, axum, tower-http, etc., which
//! are gated behind the `server` feature so the wasm build (used by
//! `dx serve` for hydration) doesn't try to compile them.

#[cfg(feature = "server")]
pub mod runtime_lock;

#[cfg(feature = "server")]
pub mod server;
