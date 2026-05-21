//! Jellyfin media-server adapter.
//!
//! Port of `lib/mydia/media_server/client/jellyfin.ex`. Two endpoints:
//!
//! - `GET /System/Info` — health check.
//! - `POST /Library/Refresh` — trigger a library scan.
//!
//! Jellyfin's library-refresh API doesn't accept a path hint the way
//! Plex's does, so [`MediaServerClient::update_library`] always
//! triggers a full scan, regardless of `opts.path`.

use std::time::Duration;

use async_trait::async_trait;
use tracing::info;

use crate::error::IntegrationError;
use crate::media_server::client::{MediaServerClient, MediaServerConfig, UpdateLibraryOpts};

const DEFAULT_TIMEOUT_MS: u64 = 30_000;

#[derive(Debug, Clone)]
pub struct JellyfinClient {
    inner: reqwest::Client,
}

impl JellyfinClient {
    pub fn new() -> Result<Self, IntegrationError> {
        let inner = reqwest::Client::builder()
            .user_agent(format!(
                "Mydia-rs/{} ({})",
                env!("CARGO_PKG_VERSION"),
                std::env::consts::ARCH
            ))
            .timeout(Duration::from_millis(DEFAULT_TIMEOUT_MS))
            .build()?;
        Ok(Self { inner })
    }

    pub fn with_client(inner: reqwest::Client) -> Self {
        Self { inner }
    }

    fn build_url(config: &MediaServerConfig, path: &str) -> String {
        let base = config.url.trim_end_matches('/');
        format!("{base}{path}")
    }

    fn apply_headers(
        req: reqwest::RequestBuilder,
        config: &MediaServerConfig,
    ) -> reqwest::RequestBuilder {
        req.header("X-Emby-Token", &config.token)
            .header(
                "Authorization",
                format!("MediaBrowser Token=\"{}\"", config.token),
            )
            .header("Accept", "application/json")
    }
}

#[async_trait]
impl MediaServerClient for JellyfinClient {
    async fn test_connection(&self, config: &MediaServerConfig) -> Result<(), IntegrationError> {
        if config.url.is_empty() {
            return Err(IntegrationError::invalid_config("URL is required"));
        }
        let url = Self::build_url(config, "/System/Info");
        let req = Self::apply_headers(self.inner.get(&url), config);
        let resp = req.send().await?;
        let status = resp.status();
        if status.is_success() {
            Ok(())
        } else {
            let body = resp.text().await.ok();
            Err(IntegrationError::from_response_status(
                status.as_u16(),
                None,
                body.as_deref(),
            ))
        }
    }

    async fn update_library(
        &self,
        config: &MediaServerConfig,
        _opts: &UpdateLibraryOpts<'_>,
    ) -> Result<(), IntegrationError> {
        let url = Self::build_url(config, "/Library/Refresh");
        let req = Self::apply_headers(self.inner.post(&url), config);
        info!(server = %config.name, "Triggering Jellyfin library scan");
        let resp = req.send().await?;
        let status = resp.status();
        if status.is_success() {
            // 204 No Content is the success path.
            Ok(())
        } else {
            let body = resp.text().await.ok();
            Err(IntegrationError::from_response_status(
                status.as_u16(),
                None,
                body.as_deref(),
            ))
        }
    }
}
