//! Custom-URL import-list provider.
//!
//! Port of `lib/mydia/import_lists/provider/custom_url.ex`. Accepts
//! several JSON shapes:
//!
//! 1. Plain array: `[{ "tmdb_id": 123 }, ...]`
//! 2. `{ "items": [...] }` envelope.
//! 3. `{ "results": [...] }` envelope.
//! 4. Radarr / Sonarr export format: `[{ "tmdbId": 123 }, ...]`.
//!
//! Each item must surface a TMDB ID under one of `tmdb_id`, `tmdbId`,
//! or `id`. Other fields are best-effort.

use std::time::Duration;

use async_trait::async_trait;
use tracing::{debug, info, warn};

use crate::error::IntegrationError;
use crate::import_lists::provider::{ImportItem, ImportListProvider, ImportListSpec};

const DEFAULT_TIMEOUT_MS: u64 = 30_000;

#[derive(Debug, Clone)]
pub struct CustomUrlProvider {
    inner: reqwest::Client,
}

impl CustomUrlProvider {
    pub fn new() -> Result<Self, IntegrationError> {
        let inner = reqwest::Client::builder()
            .user_agent("Mydia/1.0")
            .timeout(Duration::from_millis(DEFAULT_TIMEOUT_MS))
            .build()?;
        Ok(Self { inner })
    }

    pub fn with_client(inner: reqwest::Client) -> Self {
        Self { inner }
    }

    async fn fetch_from_url(
        &self,
        url: &str,
        media_type: &str,
    ) -> Result<Vec<ImportItem>, IntegrationError> {
        info!(%url, "Fetching custom URL import list");
        let resp = self
            .inner
            .get(url)
            .header("accept", "application/json")
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
        let body: serde_json::Value = resp.json().await?;
        let items = extract_items(&body)?;
        Ok(parse_items(items, media_type))
    }
}

impl Default for CustomUrlProvider {
    fn default() -> Self {
        Self::new().expect("default client builds")
    }
}

#[async_trait]
impl ImportListProvider for CustomUrlProvider {
    fn supports(&self, list_type: &str) -> bool {
        list_type == "custom_url"
    }

    async fn fetch_items(
        &self,
        spec: &ImportListSpec,
    ) -> Result<Vec<ImportItem>, IntegrationError> {
        if !self.supports(&spec.list_type) {
            return Err(IntegrationError::invalid_config(
                "Invalid import list type for CustomURL provider",
            ));
        }
        let url = spec
            .config
            .get("list_url")
            .and_then(|v| v.as_str())
            .ok_or_else(|| IntegrationError::invalid_config("No URL configured"))?;
        self.fetch_from_url(url, &spec.media_type).await
    }
}

fn extract_items(body: &serde_json::Value) -> Result<Vec<serde_json::Value>, IntegrationError> {
    match body {
        serde_json::Value::Array(arr) => Ok(arr.clone()),
        serde_json::Value::Object(obj) => {
            if let Some(serde_json::Value::Array(items)) = obj.get("items") {
                Ok(items.clone())
            } else if let Some(serde_json::Value::Array(items)) = obj.get("results") {
                Ok(items.clone())
            } else {
                warn!("Unexpected custom URL response format");
                Err(IntegrationError::parse(
                    "Unexpected JSON format - expected array or object with items/results key",
                ))
            }
        }
        _ => Err(IntegrationError::parse(
            "Unexpected JSON format - expected array or object",
        )),
    }
}

fn parse_items(items: Vec<serde_json::Value>, media_type: &str) -> Vec<ImportItem> {
    let total = items.len();
    let parsed: Vec<ImportItem> = items
        .into_iter()
        .filter_map(|item| parse_item(&item, media_type))
        .collect();
    info!(
        "Parsed {} items from {} entries (custom_url)",
        parsed.len(),
        total
    );
    parsed
}

fn parse_item(item: &serde_json::Value, media_type: &str) -> Option<ImportItem> {
    let raw = item.as_object()?;
    let tmdb_id = get_tmdb_id(raw)?;
    Some(ImportItem {
        tmdb_id,
        title: get_title(raw),
        year: get_year(raw),
        poster_path: get_poster_path(raw),
        media_type: media_type.to_owned(),
    })
}

fn get_tmdb_id(raw: &serde_json::Map<String, serde_json::Value>) -> Option<i64> {
    for key in ["tmdb_id", "tmdbId", "id"] {
        if let Some(v) = raw.get(key) {
            if let Some(n) = v.as_i64() {
                return Some(n);
            }
            if let Some(s) = v.as_str() {
                if let Ok(n) = s.parse::<i64>() {
                    return Some(n);
                }
            }
        }
    }
    debug!("Skipping item without tmdb_id");
    None
}

fn get_title(raw: &serde_json::Map<String, serde_json::Value>) -> String {
    for key in ["title", "name", "originalTitle"] {
        if let Some(v) = raw.get(key).and_then(|v| v.as_str()) {
            return v.to_owned();
        }
    }
    "Unknown".into()
}

fn get_year(raw: &serde_json::Map<String, serde_json::Value>) -> Option<i32> {
    // Direct year field.
    if let Some(n) = raw.get("year").and_then(serde_json::Value::as_i64) {
        return Some(n as i32);
    }
    if let Some(s) = raw.get("year").and_then(|v| v.as_str()) {
        if let Ok(n) = s.parse::<i32>() {
            return Some(n);
        }
    }
    // Date-style fields — first 4 chars as year.
    for key in ["release_date", "first_air_date", "releaseDate"] {
        if let Some(s) = raw.get(key).and_then(|v| v.as_str()) {
            if s.len() >= 4 {
                if let Some(prefix) = s.get(..4) {
                    if let Ok(n) = prefix.parse::<i32>() {
                        return Some(n);
                    }
                }
            }
        }
    }
    None
}

fn get_poster_path(raw: &serde_json::Map<String, serde_json::Value>) -> Option<String> {
    for key in ["poster_path", "posterPath", "poster"] {
        if let Some(v) = raw.get(key).and_then(|v| v.as_str()) {
            return Some(v.to_owned());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_plain_array() {
        let json = serde_json::json!([
            {"tmdb_id": 123, "title": "Foo", "year": 2020},
            {"tmdbId": 456, "name": "Bar", "first_air_date": "2018-05-01"}
        ]);
        let items = extract_items(&json).unwrap();
        let parsed = parse_items(items, "movie");
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].tmdb_id, 123);
        assert_eq!(parsed[0].year, Some(2020));
        assert_eq!(parsed[1].tmdb_id, 456);
        assert_eq!(parsed[1].title, "Bar");
        assert_eq!(parsed[1].year, Some(2018));
    }

    #[test]
    fn parses_items_envelope() {
        let json = serde_json::json!({"items": [{"tmdb_id": 42, "title": "Answer"}]});
        let items = extract_items(&json).unwrap();
        let parsed = parse_items(items, "movie");
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].tmdb_id, 42);
    }

    #[test]
    fn parses_results_envelope() {
        let json = serde_json::json!({"results": [{"id": "777"}]});
        let items = extract_items(&json).unwrap();
        let parsed = parse_items(items, "movie");
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].tmdb_id, 777);
    }

    #[test]
    fn rejects_garbage_shape() {
        let json = serde_json::json!({"unexpected": "shape"});
        assert!(extract_items(&json).is_err());
    }

    #[test]
    fn skips_items_without_tmdb_id() {
        let json = serde_json::json!([{"title": "Missing ID"}, {"tmdb_id": 1}]);
        let items = extract_items(&json).unwrap();
        let parsed = parse_items(items, "movie");
        assert_eq!(parsed.len(), 1);
    }
}
