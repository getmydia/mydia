//! Import-list provider adapters.
//!
//! Port of `lib/mydia/import_lists/provider*`. The Phoenix module uses
//! `@behaviour Mydia.ImportLists.Provider`; the Rust port mirrors that
//! shape with the [`provider::ImportListProvider`] trait. Two
//! implementations land here:
//!
//! - [`tmdb`] — preset TMDB lists (trending, popular, upcoming, etc.)
//!   plus user-created TMDB lists via `tmdb_list`. All requests go
//!   through the metadata-relay.
//! - [`custom_url`] — user-provided JSON endpoint (Radarr/Sonarr export
//!   format, plain `tmdb_id` array, or `{items: [...]}` envelope).
//!
//! A registry that selects a provider for a given list type is part
//! of the U17 worker; this crate stays adapter-only.

pub mod custom_url;
pub mod provider;
pub mod tmdb;

pub use custom_url::CustomUrlProvider;
pub use provider::{ImportItem, ImportListProvider, ImportListSpec};
pub use tmdb::TmdbProvider;
