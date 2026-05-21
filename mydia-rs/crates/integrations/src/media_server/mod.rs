//! Media-server clients (Plex, Jellyfin) plus the watched-status sync
//! orchestrator.
//!
//! Port of `lib/mydia/media_server/`. Each adapter implements the
//! [`client::MediaServerClient`] trait so `Notifier::notify_all` can
//! dispatch uniformly. Watched-status sync is split into a
//! per-adapter trait ([`watched_sync::WatchedSyncAdapter`]) and a
//! generic orchestrator that drives import + export.

pub mod client;
pub mod jellyfin;
pub mod notifier;
pub mod plex;
pub mod plex_oauth;
pub mod watched_sync;

pub use client::{MediaServerClient, MediaServerConfig, MediaServerKind};
pub use jellyfin::JellyfinClient;
pub use notifier::Notifier;
pub use plex::PlexClient;
