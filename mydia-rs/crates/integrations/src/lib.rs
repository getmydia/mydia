//! Integrations & infrastructure domain layer.
//!
//! Port of `lib/mydia/crash_reporter/`, `lib/mydia/integrations/`,
//! `lib/mydia/import_lists/provider*`, and `lib/mydia/media_server/`.
//!
//! This crate ships the ~5.4k LOC of domain-layer logic that U17's
//! apalis workers depend on but is not itself worker code:
//!
//! - [`crash_reporter`] — local queue + sender + sanitizer + tracing-layer
//!   bridge. Equivalent of Phoenix's `Mydia.CrashReporter` `GenServer` +
//!   `Logger` backend.
//! - [`trakt`] — HTTP client, sync, and scrobbler for Trakt.tv. Proxies
//!   every request through metadata-relay so `client_id`/`client_secret`
//!   never leave the dev-owned service.
//! - [`user_integration`] — Phoenix `user_integrations` row shape +
//!   `token_expired?` helper.
//! - [`import_lists`] — `ImportListProvider` trait plus the TMDB and
//!   `custom_url` adapters.
//! - [`media_server`] — Plex / Jellyfin clients, notifier, watched-sync
//!   orchestrator, and Plex OAuth PIN-pairing flow.
//!
//! HTTP boundary: every external call goes through `reqwest::Client`.
//! All errors land in [`error::IntegrationError`] so worker call sites
//! can pattern-match on a single enum.

pub mod crash_reporter;
pub mod error;
pub mod import_lists;
pub mod media_server;
pub mod trakt;
pub mod user_integration;

pub use error::{ErrorKind, IntegrationError};
