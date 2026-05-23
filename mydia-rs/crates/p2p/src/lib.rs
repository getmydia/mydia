//! Direct, in-process consumer of `native/mydia_p2p_core`.
//!
//! This crate is the Rust-side parity for `lib/mydia/p2p/server.ex`:
//! the Phoenix backend wraps `mydia_p2p_core::Host` via a Rustler NIF;
//! mydia-rs consumes the same crate directly without an FFI hop.
//!
//! ## Module layout
//!
//! - [`media_token`]: adapter that combines `mydia_rs_auth::MediaTokenCache`
//!   with a DB lookup against `remote_devices`. The auth crate (U6)
//!   already ships the JWT signer and the in-memory dashmap cache; this
//!   module adds the fallback path that confirms the device row exists
//!   and is not revoked, and exposes synchronous evict-on-revoke.
//! - [`claim`]: claim-code generation + validation (port of
//!   `lib/mydia/remote_access/pairing_claim.ex`) and the consume
//!   transition.
//! - [`pairing`]: the orchestration that takes a relay-paired claim
//!   code + device attrs, creates the `remote_devices` row, and issues
//!   the trio of tokens (media token, access token, device token).
//! - [`rate_limiter`]: atomic claim-failure rate limiter using
//!   `dashmap` entry-API operations so 100 concurrent failures produce
//!   at most N successes (where N is the threshold), never N+k. The
//!   Phoenix side has a known non-atomic increment hazard
//!   (`lib/mydia/remote_access/claim_rate_limiter.ex`); we close it here.
//! - [`router`]: request dispatch. Incoming
//!   `mydia_p2p_core::MydiaRequest` variants route through the
//!   [`router::P2pRouter`] trait so the [`server`] event loop stays
//!   thin and the dispatch targets (GraphQL schema, HLS supervisor,
//!   pairing) plug in by trait object.
//! - [`server`]: the event-loop wrapper. Holds the
//!   `mydia_p2p_core::Host` (which itself owns an OS-thread Tokio
//!   runtime), spawns one task per incoming long-lived stream, and
//!   wraps every blocking `Host` method in
//!   `tokio::task::spawn_blocking` to keep the async runtime free of
//!   deadlocks.
//!
//! ## Blocking-API discipline
//!
//! `Host::dial`, `Host::get_node_addr`, `Host::send_response`,
//! `Host::get_network_stats`, and the HLS send/stream methods all use
//! `cmd_tx.blocking_send` + `rx.blocking_recv` against the Host's
//! own runtime. Calling them from an async context risks blocking the
//! tokio worker (and on a single-threaded runtime, deadlocking).
//!
//! Every call site in this crate that touches a blocking Host method
//! lives inside `tokio::task::spawn_blocking`. The app boot
//! (`crates/app/src/main.rs`) provisions the runtime with enough
//! blocking-thread headroom (`max_blocking_threads`) to absorb peak
//! concurrent requests without starvation.
//!
//! See [`server`] for the `spawn_blocking` wrappers and
//! [`router::P2pRouter`] for the dispatch contract.

pub mod claim;
pub mod default_router;
pub mod media_token;
pub mod pairing;
pub mod rate_limiter;
pub mod router;
pub mod server;

pub use claim::{
    consume_claim_code, generate_claim_code, normalize_claim_code, validate_claim_code,
    ClaimCodeError, ClaimCodeOutcome, CLAIM_CODE_DEFAULT_TTL,
};
pub use default_router::MinimalRouter;
pub use media_token::{MediaTokenValidator, ValidationError};
pub use pairing::{complete_pairing, DeviceAttrs, PairingError, PairingOutcome};
pub use rate_limiter::{ClaimRateLimiter, RateLimitOutcome};
pub use router::{P2pRouter, RouterContext, RouterError};
pub use server::{Server, ServerConfig, ServerError, ServerHandle, ServerStatus};
