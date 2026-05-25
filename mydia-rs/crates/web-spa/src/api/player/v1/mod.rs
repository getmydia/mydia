//! `/api/player/v1/*` — the player-specific REST surface.
//!
//! Phoenix migrated browse / discover / search to GraphQL; only the
//! subtitle file-serving endpoints remain here. The `subtitles`
//! controller serves the actual subtitle file content (URLs are
//! returned by the GraphQL `mediaFile.subtitleTracks { url }` field).

pub mod subtitle;

use axum::Router;

pub fn router() -> Router {
    Router::new().merge(subtitle::router())
}
