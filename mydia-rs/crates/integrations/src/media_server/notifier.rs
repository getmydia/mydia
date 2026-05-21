//! Library-refresh notifier.
//!
//! Port of `lib/mydia/media_server/notifier.ex`. Fans out a library-
//! refresh call to every enabled media server. Phoenix uses
//! `Task.start` for fire-and-forget; the Rust port returns the futures
//! to the caller so the U17 worker can `tokio::join!` them with
//! per-server error capture, or detach them with `tokio::spawn`.

use std::sync::Arc;

use tracing::{info, warn};

use crate::error::IntegrationError;
use crate::media_server::client::{
    MediaServerClient, MediaServerConfig, MediaServerKind, UpdateLibraryOpts,
};
use crate::media_server::jellyfin::JellyfinClient;
use crate::media_server::plex::PlexClient;

/// Result of one server notification. The worker layer turns these
/// into events.
#[derive(Debug, Clone)]
pub struct NotifyResult {
    pub server_id: String,
    pub server_name: String,
    pub kind: MediaServerKind,
    pub outcome: Result<(), IntegrationError>,
}

/// Notifier that holds a per-kind client. Cheap to clone — the inner
/// clients hold `Arc`-shared `reqwest::Client`s.
#[derive(Clone)]
pub struct Notifier {
    plex: Arc<PlexClient>,
    jellyfin: Arc<JellyfinClient>,
}

impl Notifier {
    /// Build a notifier with default clients. Returns an error if the
    /// underlying `reqwest::Client` builder fails (extremely rare —
    /// typically only if rustls fails to initialize).
    pub fn new() -> Result<Self, IntegrationError> {
        Ok(Self {
            plex: Arc::new(PlexClient::new()?),
            jellyfin: Arc::new(JellyfinClient::new()?),
        })
    }

    /// Build a notifier with custom clients (used by tests so the
    /// `reqwest::Client` can carry a wiremock-aware connector).
    pub fn with_clients(plex: PlexClient, jellyfin: JellyfinClient) -> Self {
        Self {
            plex: Arc::new(plex),
            jellyfin: Arc::new(jellyfin),
        }
    }

    /// Notify one media server. Mirrors `Notifier.notify_server/2`.
    ///
    /// Returns the typed result so the worker can log or record it as
    /// an event. The worker is responsible for not propagating
    /// failures upstream (notifications are "informational").
    pub async fn notify_server(
        &self,
        config: &MediaServerConfig,
        opts: &UpdateLibraryOpts<'_>,
    ) -> NotifyResult {
        let outcome = match config.kind {
            MediaServerKind::Plex => self.plex.update_library(config, opts).await,
            MediaServerKind::Jellyfin | MediaServerKind::Emby => {
                self.jellyfin.update_library(config, opts).await
            }
        };
        match &outcome {
            Ok(()) => info!(server = %config.name, kind = ?config.kind, "Notified media server"),
            Err(err) => warn!(server = %config.name, error = %err, "Failed to notify media server"),
        }
        NotifyResult {
            server_id: config.id.clone(),
            server_name: config.name.clone(),
            kind: config.kind,
            outcome,
        }
    }

    /// Notify every enabled server in `configs`. Each future runs
    /// concurrently; results are returned in the same order as the
    /// input slice.
    pub async fn notify_all(
        &self,
        configs: &[MediaServerConfig],
        opts: &UpdateLibraryOpts<'_>,
    ) -> Vec<NotifyResult> {
        let enabled: Vec<_> = configs.iter().filter(|c| c.enabled).collect();
        if enabled.is_empty() {
            return Vec::new();
        }
        info!(
            "Notifying {} media server(s) to refresh libraries",
            enabled.len()
        );
        let futures = enabled.into_iter().map(|c| self.notify_server(c, opts));
        futures::future::join_all(futures).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn empty_config_list_is_noop() {
        let notifier = Notifier::new().unwrap();
        let results = notifier
            .notify_all(&[], &UpdateLibraryOpts::default())
            .await;
        assert!(results.is_empty());
    }

    #[tokio::test]
    async fn disabled_servers_are_skipped() {
        let notifier = Notifier::new().unwrap();
        let config = MediaServerConfig {
            id: "abc".into(),
            kind: MediaServerKind::Plex,
            name: "test".into(),
            url: "http://localhost".into(),
            token: "token".into(),
            enabled: false,
        };
        let results = notifier
            .notify_all(&[config], &UpdateLibraryOpts::default())
            .await;
        assert!(results.is_empty());
    }
}
