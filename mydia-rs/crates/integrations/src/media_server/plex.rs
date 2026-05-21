//! Plex media-server adapter.
//!
//! Port of `lib/mydia/media_server/client/plex.ex`. Holds the
//! `reqwest::Client` and the Plex-specific endpoint helpers
//! (`/library/sections`, `/library/metadata/<key>/allLeaves`,
//! `:/scrobble`). Used by:
//!
//! - [`super::Notifier`] for library-refresh fire-and-forget.
//! - [`super::watched_sync`] for fetching and marking watched status.

use std::collections::BTreeMap;
use std::time::Duration;

use async_trait::async_trait;
use serde::Deserialize;
use tracing::info;

use crate::error::IntegrationError;
use crate::media_server::client::{MediaServerClient, MediaServerConfig, UpdateLibraryOpts};

const DEFAULT_TIMEOUT_MS: u64 = 30_000;

/// One library section returned by `/library/sections`. Mirrors the
/// Elixir port's `%{key, type, title}` shape.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexSection {
    pub key: String,
    pub kind: String,
    pub title: String,
}

/// One library item returned by `/library/sections/<key>/all`.
#[derive(Debug, Clone)]
pub struct PlexItem {
    pub rating_key: String,
    pub title: String,
    pub kind: String,
    pub view_count: i32,
    pub last_viewed_at: Option<i64>,
    pub guids: BTreeMap<String, String>,
}

/// One episode (leaf) returned by `/library/metadata/<show-rating-key>/allLeaves`.
#[derive(Debug, Clone)]
pub struct PlexEpisode {
    pub rating_key: String,
    pub title: String,
    pub season_number: Option<i32>,
    pub episode_number: Option<i32>,
    pub view_count: i32,
    pub last_viewed_at: Option<i64>,
    pub guids: BTreeMap<String, String>,
}

#[derive(Debug, Clone)]
pub struct PlexClient {
    inner: reqwest::Client,
}

impl PlexClient {
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

    fn headers(config: &MediaServerConfig) -> Vec<(&'static str, String)> {
        vec![
            ("X-Plex-Token", config.token.clone()),
            ("Accept", "application/json".into()),
        ]
    }

    fn apply_headers(
        req: reqwest::RequestBuilder,
        config: &MediaServerConfig,
    ) -> reqwest::RequestBuilder {
        let mut out = req;
        for (k, v) in Self::headers(config) {
            out = out.header(k, v);
        }
        out
    }

    async fn get<T: serde::de::DeserializeOwned>(
        &self,
        config: &MediaServerConfig,
        path: &str,
        params: &[(&str, &str)],
    ) -> Result<T, IntegrationError> {
        let url = Self::build_url(config, path);
        let req = self.inner.get(&url).query(params);
        let req = Self::apply_headers(req, config);
        let resp = req.send().await?;
        let status = resp.status();
        if status.is_success() {
            resp.json::<T>().await.map_err(IntegrationError::from)
        } else {
            let body = resp.text().await.ok();
            Err(IntegrationError::from_response_status(
                status.as_u16(),
                None,
                body.as_deref(),
            ))
        }
    }

    /// `GET /library/sections`.
    pub async fn list_sections(
        &self,
        config: &MediaServerConfig,
    ) -> Result<Vec<PlexSection>, IntegrationError> {
        let body: PlexEnvelope<PlexDirectoryWrapper> =
            self.get(config, "/library/sections", &[]).await?;
        Ok(body
            .media_container
            .directory
            .unwrap_or_default()
            .into_iter()
            .map(|d| PlexSection {
                key: d.key.unwrap_or_default(),
                kind: d.kind.unwrap_or_default(),
                title: d.title.unwrap_or_default(),
            })
            .collect())
    }

    /// `GET /library/sections/<section_key>/all?includeGuids=1`.
    pub async fn list_section_items(
        &self,
        config: &MediaServerConfig,
        section_key: &str,
    ) -> Result<Vec<PlexItem>, IntegrationError> {
        let path = format!("/library/sections/{section_key}/all");
        let body: PlexEnvelope<PlexMetadataWrapper> =
            self.get(config, &path, &[("includeGuids", "1")]).await?;
        Ok(body
            .media_container
            .metadata
            .unwrap_or_default()
            .into_iter()
            .map(|m| PlexItem {
                rating_key: m.rating_key.unwrap_or_default(),
                title: m.title.unwrap_or_default(),
                kind: m.kind.unwrap_or_default(),
                view_count: m.view_count.unwrap_or(0),
                last_viewed_at: m.last_viewed_at,
                guids: parse_guids(m.guid.as_deref()),
            })
            .collect())
    }

    /// `GET /library/metadata/<show_rating_key>/allLeaves?includeGuids=1`.
    pub async fn list_show_episodes(
        &self,
        config: &MediaServerConfig,
        show_rating_key: &str,
    ) -> Result<Vec<PlexEpisode>, IntegrationError> {
        let path = format!("/library/metadata/{show_rating_key}/allLeaves");
        let body: PlexEnvelope<PlexMetadataWrapper> =
            self.get(config, &path, &[("includeGuids", "1")]).await?;
        Ok(body
            .media_container
            .metadata
            .unwrap_or_default()
            .into_iter()
            .map(|m| PlexEpisode {
                rating_key: m.rating_key.unwrap_or_default(),
                title: m.title.unwrap_or_default(),
                season_number: m.parent_index,
                episode_number: m.index,
                view_count: m.view_count.unwrap_or(0),
                last_viewed_at: m.last_viewed_at,
                guids: parse_guids(m.guid.as_deref()),
            })
            .collect())
    }

    /// `GET /:/scrobble?identifier=...&key=...` — mark an item watched.
    pub async fn scrobble(
        &self,
        config: &MediaServerConfig,
        rating_key: &str,
    ) -> Result<(), IntegrationError> {
        let url = Self::build_url(config, "/:/scrobble");
        let req = self.inner.get(&url).query(&[
            ("identifier", "com.plexapp.plugins.library"),
            ("key", rating_key),
        ]);
        let req = Self::apply_headers(req, config);
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

    /// `GET /:/unscrobble?identifier=...&key=...` — mark an item unwatched.
    pub async fn unscrobble(
        &self,
        config: &MediaServerConfig,
        rating_key: &str,
    ) -> Result<(), IntegrationError> {
        let url = Self::build_url(config, "/:/unscrobble");
        let req = self.inner.get(&url).query(&[
            ("identifier", "com.plexapp.plugins.library"),
            ("key", rating_key),
        ]);
        let req = Self::apply_headers(req, config);
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
}

#[async_trait]
impl MediaServerClient for PlexClient {
    async fn test_connection(&self, config: &MediaServerConfig) -> Result<(), IntegrationError> {
        if config.url.is_empty() {
            return Err(IntegrationError::invalid_config("URL is required"));
        }
        if config.token.is_empty() {
            return Err(IntegrationError::invalid_config("Token is required"));
        }
        let url = Self::build_url(config, "/identity");
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
        opts: &UpdateLibraryOpts<'_>,
    ) -> Result<(), IntegrationError> {
        let url = Self::build_url(config, "/library/sections/all/refresh");
        let mut req = self.inner.get(&url);
        if let Some(path) = opts.path {
            req = req.query(&[("path", path)]);
        }
        let req = Self::apply_headers(req, config);
        info!(server = %config.name, path = opts.path, "Triggering Plex library scan");
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
}

/// Parse a Plex GUID list (`Guid` field on items / episodes) into a
/// `BTreeMap` of provider → ID. Sorted because the downstream key
/// lookups need stable iteration order.
///
/// The Plex shape can be either an array of objects (`[{id: "tmdb://..."}]`)
/// or `null`; we accept both via `Option<&str>` carrying a JSON-encoded
/// string when present.
#[must_use]
pub fn parse_guids(raw: Option<&str>) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let Some(raw) = raw else {
        return out;
    };
    let Ok(parsed): Result<serde_json::Value, _> = serde_json::from_str(raw) else {
        return out;
    };
    if let Some(arr) = parsed.as_array() {
        for entry in arr {
            if let Some(id) = entry.get("id").and_then(|v| v.as_str()) {
                if let Some((provider, value)) = parse_one_guid(id) {
                    out.insert(provider, value);
                }
            }
        }
    }
    out
}

fn parse_one_guid(id: &str) -> Option<(String, String)> {
    for provider in ["tmdb", "imdb", "tvdb"] {
        let prefix = format!("{provider}://");
        if let Some(rest) = id.strip_prefix(&prefix) {
            return Some((provider.to_owned(), rest.to_owned()));
        }
    }
    None
}

/// Top-level envelope: `{"MediaContainer": { ... }}`.
#[derive(Debug, Deserialize)]
struct PlexEnvelope<T> {
    #[serde(rename = "MediaContainer")]
    media_container: T,
}

#[derive(Debug, Deserialize)]
struct PlexDirectoryWrapper {
    #[serde(rename = "Directory")]
    #[serde(default)]
    directory: Option<Vec<PlexDirectoryRaw>>,
}

#[derive(Debug, Deserialize)]
struct PlexDirectoryRaw {
    #[serde(default)]
    key: Option<String>,
    #[serde(default, rename = "type")]
    kind: Option<String>,
    #[serde(default)]
    title: Option<String>,
}

#[derive(Debug, Deserialize)]
struct PlexMetadataWrapper {
    #[serde(rename = "Metadata")]
    #[serde(default)]
    metadata: Option<Vec<PlexMetadataRaw>>,
}

#[derive(Debug, Deserialize)]
struct PlexMetadataRaw {
    #[serde(default, rename = "ratingKey")]
    rating_key: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default, rename = "type")]
    kind: Option<String>,
    #[serde(default, rename = "viewCount")]
    view_count: Option<i32>,
    #[serde(default, rename = "lastViewedAt")]
    last_viewed_at: Option<i64>,
    #[serde(default, rename = "parentIndex")]
    parent_index: Option<i32>,
    #[serde(default)]
    index: Option<i32>,
    /// JSON-encoded `[{id: "tmdb://..."}]` array, or null.
    #[serde(default, rename = "Guid")]
    #[serde(deserialize_with = "deserialize_guid_as_string")]
    guid: Option<String>,
}

fn deserialize_guid_as_string<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let v = serde_json::Value::deserialize(deserializer)?;
    if v.is_null() {
        return Ok(None);
    }
    Ok(Some(v.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_guids_extracts_known_providers() {
        let raw = r#"[{"id":"tmdb://12345"},{"id":"imdb://tt9999999"},{"id":"unknown://x"}]"#;
        let guids = parse_guids(Some(raw));
        assert_eq!(guids.get("tmdb").unwrap(), "12345");
        assert_eq!(guids.get("imdb").unwrap(), "tt9999999");
        assert!(!guids.contains_key("unknown"));
    }

    #[test]
    fn parse_guids_handles_null() {
        let guids = parse_guids(None);
        assert!(guids.is_empty());
    }

    #[test]
    fn parse_one_guid_accepts_canonical_providers() {
        assert_eq!(
            parse_one_guid("tmdb://42").unwrap(),
            ("tmdb".to_owned(), "42".to_owned())
        );
        assert_eq!(
            parse_one_guid("tvdb://9").unwrap(),
            ("tvdb".to_owned(), "9".to_owned())
        );
        assert!(parse_one_guid("garbage").is_none());
    }
}
