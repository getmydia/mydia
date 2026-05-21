//! Trakt.tv integration.
//!
//! Port of `lib/mydia/integrations/trakt/`. Three sub-modules:
//!
//! - [`client`] — `reqwest::Client` wrapper that talks to the
//!   metadata-relay's `/trakt/*` proxy routes. The relay holds the
//!   `client_id`/`client_secret`; this client only carries the user's
//!   access token via `X-Trakt-User-Token`.
//! - [`sync`] — collection / history / watchlist sync helpers. The
//!   actual DB writes live in U17's `TraktSync` worker; this module
//!   exposes the payload builders and the matching policy so the
//!   worker stays thin.
//! - [`scrobbler`] — real-time playback signaling (start / pause /
//!   stop). Fire-and-forget from the playback resolver in U11.

pub mod client;
pub mod scrobbler;
pub mod sync;

pub use client::TraktClient;
