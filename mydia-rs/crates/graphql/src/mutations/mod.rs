//! GraphQL mutation resolvers. Each module ports one Phoenix
//! mutation family from `lib/mydia_web/schema/resolvers/`:
//!
//! - [`playback`] — update_*_progress, mark_*_watched/unwatched,
//!   mark_season_watched, toggle_favorite (U11).
//! - [`streaming`] — start_streaming_session, end_streaming_session
//!   (U11; the HLS supervisor itself lands in U19).
//!
//! Remaining mutation families (auth, api_key, device, download,
//! remote_access) port in U14.
//!
//! Each resolver family lives in its own struct (e.g.
//! [`playback::PlaybackMutations`]); the top-level
//! [`crate::schema::MutationRoot`] combines them via
//! `MergedObject`.

pub mod playback;
pub mod streaming;
