//! mydia-rs app library surface.
//!
//! Exposed so the binary at `src/main.rs` and integration tests under
//! `tests/` share the same code paths. The supervision tree, HTTP
//! server, and remaining application wiring land in later units; for
//! now this hosts the runtime mutual-exclusion lock (U34).

pub mod runtime_lock;
