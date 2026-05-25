//! GraphQL mutation resolvers. Each module ports one Phoenix
//! mutation family from `lib/mydia_web/schema/resolvers/`:
//!
//! - [`playback`] — update_*_progress, mark_*_watched/unwatched,
//!   `mark_season_watched`, `toggle_favorite` (U11).
//! - [`streaming`] — `start_streaming_session`, `end_streaming_session`
//!   (U11; the HLS supervisor itself lands in U19).
//! - [`auth`] — `login` (U14; password verify + Guardian-shaped JWT).
//! - [`api_key`] — create / revoke / delete (U14).
//! - [`device`] — `revokeDevice` (U14 stub; U29 real).
//! - [`download`] — `download_options` / prepare / status / cancel
//!   (U14 stubs; U20 real).
//! - [`remote_access`] — `generate_claim_code` / `refresh_media_token`
//!   (U14 stubs; U29 real).

pub mod admin;
pub mod api_key;
pub mod auth;
pub mod device;
pub mod download;
pub mod media;
pub mod playback;
pub mod profile;
pub mod remote_access;
pub mod requests;
pub mod streaming;
