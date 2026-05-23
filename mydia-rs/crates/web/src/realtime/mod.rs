//! Real-time channels between the Dioxus client and the server.
//!
//! Each module exposes a `#[get(...)]` WebSocket server function plus
//! its typed event payload. The wire payload type is dual-target so
//! the wasm client decodes the same struct the server emits.
//!
//! U23 ships [`library_scanner`] — the deliberate fitness probe for the
//! Dioxus-vs-LiveView gap. U24+ admin/UI pages add more channels
//! following the same pattern (subscribe-on-connect, fan out the
//! `mydia-rs-pubsub` topic events to typed wire events).

pub mod downloads;
pub mod jobs_status;
pub mod library_scanner;
pub mod transcodes;
