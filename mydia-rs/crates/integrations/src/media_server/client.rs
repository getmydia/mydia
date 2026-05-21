//! Generic media-server client behaviour.
//!
//! Port of `lib/mydia/media_server/client.ex`. Phoenix dispatches
//! between Plex and Jellyfin via a single `adapter_for/1` switch; the
//! Rust port uses an `async_trait` so both adapters share the same
//! call site in the notifier and watched-sync orchestrator.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::error::IntegrationError;

/// Discriminant for [`MediaServerConfig::kind`]. Names match Phoenix's
/// `Mydia.Settings.MediaServerConfig.type` enum values
/// (`:plex` / `:jellyfin` / `:emby`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaServerKind {
    Plex,
    Jellyfin,
    Emby,
}

/// In-memory shape of a `media_server_configs` row. Constructed by
/// worker code from a sqlx fetch.
#[derive(Debug, Clone)]
pub struct MediaServerConfig {
    pub id: String,
    pub kind: MediaServerKind,
    pub name: String,
    pub url: String,
    pub token: String,
    pub enabled: bool,
}

/// Options the notifier passes to `update_library`. Matches Phoenix's
/// keyword-list `opts` shape — only `path` matters today.
#[derive(Debug, Clone, Default)]
pub struct UpdateLibraryOpts<'a> {
    pub path: Option<&'a str>,
}

/// Common interface for talking to a media server's HTTP API.
///
/// Implementations should be cheap to clone — the underlying
/// `reqwest::Client` is `Arc`-shared.
#[async_trait]
pub trait MediaServerClient: Send + Sync {
    /// Smoke test: returns `Ok(())` if the server responds to a
    /// health-check endpoint. Mirrors Phoenix's `test_connection/1`.
    async fn test_connection(&self, config: &MediaServerConfig) -> Result<(), IntegrationError>;

    /// Trigger a library scan / metadata refresh on the server.
    async fn update_library(
        &self,
        config: &MediaServerConfig,
        opts: &UpdateLibraryOpts<'_>,
    ) -> Result<(), IntegrationError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kind_serializes_snake_case() {
        let plex = serde_json::to_string(&MediaServerKind::Plex).unwrap();
        assert_eq!(plex, "\"plex\"");
        let jelly = serde_json::to_string(&MediaServerKind::Jellyfin).unwrap();
        assert_eq!(jelly, "\"jellyfin\"");
    }
}
