//! TMDB import-list provider.
//!
//! Port of `lib/mydia/import_lists/provider/tmdb.ex`. Phoenix calls the
//! metadata-relay's `/tmdb/*` proxy routes; the Rust port does the
//! same. The relay holds the TMDB API key.

use std::time::Duration;

use async_trait::async_trait;
use regex::Regex;
use serde::Deserialize;
use tracing::warn;

use crate::error::IntegrationError;
use crate::import_lists::provider::{ImportItem, ImportListProvider, ImportListSpec};

const SUPPORTED_TYPES: &[&str] = &[
    "tmdb_trending",
    "tmdb_popular",
    "tmdb_upcoming",
    "tmdb_now_playing",
    "tmdb_on_the_air",
    "tmdb_airing_today",
    "tmdb_list",
];

const DEFAULT_TIMEOUT_MS: u64 = 30_000;

#[derive(Debug, Clone)]
pub struct TmdbProvider {
    inner: reqwest::Client,
    base_url: String,
}

impl TmdbProvider {
    /// Build a provider pointing at the given metadata-relay base URL.
    pub fn new(base_url: impl Into<String>) -> Result<Self, IntegrationError> {
        let base_url = base_url.into();
        if base_url.is_empty() {
            return Err(IntegrationError::invalid_config("base_url is required"));
        }
        let inner = reqwest::Client::builder()
            .user_agent(format!(
                "Mydia-rs/{} ({})",
                env!("CARGO_PKG_VERSION"),
                std::env::consts::ARCH
            ))
            .timeout(Duration::from_millis(DEFAULT_TIMEOUT_MS))
            .build()?;
        Ok(Self { inner, base_url })
    }

    /// Build a provider with a custom `reqwest::Client` (for tests).
    pub fn with_client(base_url: impl Into<String>, inner: reqwest::Client) -> Self {
        Self {
            inner,
            base_url: base_url.into(),
        }
    }

    fn join(&self, path: &str) -> String {
        let base = self.base_url.trim_end_matches('/');
        if path.starts_with('/') {
            format!("{base}{path}")
        } else {
            format!("{base}/{path}")
        }
    }

    async fn fetch_preset(
        &self,
        list_type: &str,
        media_type: &str,
    ) -> Result<Vec<ImportItem>, IntegrationError> {
        let endpoint = build_endpoint(list_type, media_type);
        let url = self.join(endpoint);
        let resp = self
            .inner
            .get(&url)
            .query(&[("language", "en-US"), ("page", "1")])
            .send()
            .await?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.ok();
            return Err(IntegrationError::from_response_status(
                status.as_u16(),
                None,
                body.as_deref(),
            ));
        }
        let body: TmdbListResponse = resp.json().await?;
        Ok(body
            .results
            .into_iter()
            .map(|r| parse_result(r, media_type))
            .collect())
    }

    async fn fetch_user_list(
        &self,
        list_id: &str,
        media_type: &str,
    ) -> Result<Vec<ImportItem>, IntegrationError> {
        let endpoint = format!("/tmdb/list/{list_id}");
        let url = self.join(&endpoint);
        let resp = self
            .inner
            .get(&url)
            .query(&[("language", "en-US")])
            .send()
            .await?;
        let status = resp.status();
        if status.as_u16() == 404 {
            return Err(IntegrationError::not_found(format!(
                "TMDB list not found (ID: {list_id})"
            )));
        }
        if !status.is_success() {
            let body = resp.text().await.ok();
            return Err(IntegrationError::from_response_status(
                status.as_u16(),
                None,
                body.as_deref(),
            ));
        }
        let body: TmdbUserListResponse = resp.json().await.map_err(|err| {
            warn!("Unexpected TMDB list response: {err}");
            IntegrationError::from(err)
        })?;
        Ok(body
            .items
            .into_iter()
            .filter(|r| matches_media_type(r.media_type.as_deref(), media_type))
            .map(|r| parse_result(r, media_type))
            .collect())
    }
}

#[async_trait]
impl ImportListProvider for TmdbProvider {
    fn supports(&self, list_type: &str) -> bool {
        SUPPORTED_TYPES.contains(&list_type)
    }

    async fn fetch_items(
        &self,
        spec: &ImportListSpec,
    ) -> Result<Vec<ImportItem>, IntegrationError> {
        if spec.list_type == "tmdb_list" {
            let list_url = spec
                .config
                .get("list_url")
                .and_then(|v| v.as_str())
                .ok_or_else(|| IntegrationError::invalid_config("No list ID configured"))?;
            let list_id = extract_list_id(list_url).ok_or_else(|| {
                IntegrationError::invalid_config(format!("Invalid TMDB list URL: {list_url}"))
            })?;
            self.fetch_user_list(&list_id, &spec.media_type).await
        } else if self.supports(&spec.list_type) {
            self.fetch_preset(&spec.list_type, &spec.media_type).await
        } else {
            Err(IntegrationError::invalid_config(format!(
                "Unsupported TMDB list type: {}",
                spec.list_type
            )))
        }
    }
}

fn build_endpoint(list_type: &str, media_type: &str) -> &'static str {
    // Each arm spells out its tuple — the wildcard fallback duplicates
    // the first arm intentionally so the call-site reads as a complete
    // dispatch table. Phoenix's port has the same shape.
    #[allow(clippy::match_same_arms)]
    match (list_type, media_type) {
        ("tmdb_trending", "movie") => "/tmdb/movies/trending",
        ("tmdb_trending", "tv_show") => "/tmdb/tv/trending",
        ("tmdb_popular", "movie") => "/tmdb/movies/popular",
        ("tmdb_popular", "tv_show") => "/tmdb/tv/popular",
        ("tmdb_upcoming", "movie") => "/tmdb/movies/upcoming",
        ("tmdb_now_playing", "movie") => "/tmdb/movies/now_playing",
        ("tmdb_on_the_air", "tv_show") => "/tmdb/tv/on_the_air",
        ("tmdb_airing_today", "tv_show") => "/tmdb/tv/airing_today",
        // Fallback for invalid combos — mirror Phoenix's permissive fallback.
        _ => "/tmdb/movies/trending",
    }
}

fn matches_media_type(item_media_type: Option<&str>, expected: &str) -> bool {
    matches!(
        (item_media_type, expected),
        (Some("movie"), "movie") | (Some("tv"), "tv_show") | (None, _)
    )
}

#[derive(Debug, Deserialize)]
struct TmdbListResponse {
    #[serde(default)]
    results: Vec<TmdbResult>,
}

#[derive(Debug, Deserialize)]
struct TmdbUserListResponse {
    #[serde(default)]
    items: Vec<TmdbResult>,
}

#[derive(Debug, Deserialize)]
struct TmdbResult {
    id: i64,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    poster_path: Option<String>,
    #[serde(default)]
    release_date: Option<String>,
    #[serde(default)]
    first_air_date: Option<String>,
    #[serde(default)]
    media_type: Option<String>,
}

fn parse_result(r: TmdbResult, media_type: &str) -> ImportItem {
    let year = r
        .release_date
        .as_deref()
        .and_then(extract_year)
        .or_else(|| r.first_air_date.as_deref().and_then(extract_year));
    ImportItem {
        tmdb_id: r.id,
        title: r.title.or(r.name).unwrap_or_default(),
        year,
        poster_path: r.poster_path,
        media_type: media_type.to_owned(),
    }
}

fn extract_year(date: &str) -> Option<i32> {
    if date.len() < 4 {
        return None;
    }
    date.get(..4)?.parse::<i32>().ok()
}

/// Extract a TMDB list ID from a raw ID or a TMDB list URL.
///
/// Accepts:
/// - Pure numeric strings (`"12345"`).
/// - Full TMDB list URLs (`https://www.themoviedb.org/list/12345`).
fn extract_list_id(input: &str) -> Option<String> {
    if input.chars().all(|c| c.is_ascii_digit()) && !input.is_empty() {
        return Some(input.to_owned());
    }
    let re = Regex::new(r"/list/(\d+)").ok()?;
    re.captures(input)
        .and_then(|caps| caps.get(1).map(|m| m.as_str().to_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn supports_known_types() {
        let p = TmdbProvider::new("http://localhost").unwrap();
        assert!(p.supports("tmdb_trending"));
        assert!(p.supports("tmdb_list"));
        assert!(!p.supports("custom_url"));
    }

    #[test]
    fn extract_year_from_iso_date() {
        assert_eq!(extract_year("2010-07-15"), Some(2010));
        assert_eq!(extract_year("bad"), None);
        assert_eq!(extract_year(""), None);
    }

    #[test]
    fn extract_list_id_from_numeric_or_url() {
        assert_eq!(extract_list_id("12345"), Some("12345".into()));
        assert_eq!(
            extract_list_id("https://www.themoviedb.org/list/9876"),
            Some("9876".into())
        );
        assert_eq!(extract_list_id("not-a-list"), None);
    }

    #[test]
    fn matches_media_type_handles_tmdb_aliases() {
        assert!(matches_media_type(Some("movie"), "movie"));
        assert!(matches_media_type(Some("tv"), "tv_show"));
        assert!(matches_media_type(None, "movie")); // no media_type → include
        assert!(!matches_media_type(Some("movie"), "tv_show"));
    }

    #[test]
    fn build_endpoint_falls_back_for_invalid_combo() {
        // movie + on_the_air doesn't exist; Phoenix falls back to
        // movies/trending, we mirror it.
        assert_eq!(
            build_endpoint("tmdb_on_the_air", "movie"),
            "/tmdb/movies/trending"
        );
    }
}
