//! Subtitle endpoints on metadata-relay.
//!
//! Port of `lib/mydia/subtitles/client/metadata_relay.ex` and
//! `lib/mydia/subtitles/provider/relay.ex`. The relay proxies
//! OpenSubtitles + future subtitle providers behind a single HTTP
//! surface so credentials and rate-limit state never leak to the
//! self-hosted Mydia instance.
//!
//! Endpoints (matches the Elixir client):
//!
//! - `POST /api/v1/subtitles/search` — search by hash / IMDB / TMDB / text.
//! - `GET  /api/v1/subtitles/download-url/{file_id}` — retrieve a
//!   short-lived signed URL for the subtitle blob.

use std::time::Duration;

use async_trait::async_trait;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tracing::{debug, error, warn};

use crate::error::SubtitleError;
use crate::provider::{ProviderConfig, SubtitleProvider, SubtitleRef};
use crate::structs::{ProviderKind, QuotaInfo, SearchParams, SubtitleSearchResult};

const DEFAULT_TIMEOUT_MS: u64 = 10_000;
const MAX_RETRIES: u32 = 3;
const INITIAL_BACKOFF_MS: u64 = 1_000;

/// HTTP method discriminator used by [`MetadataRelay::send`].
enum Method<'a, B: ?Sized> {
    Get,
    Post(&'a B),
}

/// metadata-relay subtitle client.
#[derive(Clone)]
pub struct MetadataRelay {
    base_url: String,
    http: Client,
    timeout: Duration,
}

#[derive(Debug, Deserialize)]
struct SearchResponse {
    #[serde(default)]
    subtitles: Vec<serde_json::Value>,
}

/// Response shape returned by `GET /api/v1/subtitles/download-url/{file_id}`.
#[derive(Debug, Deserialize, Serialize)]
pub struct DownloadUrlResponse {
    pub download_url: String,
    #[serde(default)]
    pub file_name: Option<String>,
    #[serde(default)]
    pub requests_used: Option<u32>,
    #[serde(default)]
    pub requests_remaining: Option<u32>,
}

impl MetadataRelay {
    /// Build a client against the given base URL.
    pub fn new(base_url: impl Into<String>) -> Result<Self, SubtitleError> {
        let base_url = base_url.into();
        if base_url.is_empty() {
            return Err(SubtitleError::not_configured(
                "metadata-relay base URL is empty",
            ));
        }
        let http = Client::builder()
            .timeout(Duration::from_millis(DEFAULT_TIMEOUT_MS))
            .build()
            .map_err(SubtitleError::from)?;
        Ok(Self {
            base_url: base_url.trim_end_matches('/').to_owned(),
            http,
            timeout: Duration::from_millis(DEFAULT_TIMEOUT_MS),
        })
    }

    /// Override the per-request timeout.
    #[must_use]
    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Default-relay constructor — uses `https://relay.mydia.dev`,
    /// matching the metadata crate's default endpoint.
    pub fn default_endpoint() -> Result<Self, SubtitleError> {
        Self::new("https://relay.mydia.dev")
    }

    /// Search subtitles by hash / IMDB / etc.
    pub async fn search(
        &self,
        params: &SearchParams,
    ) -> Result<Vec<SubtitleSearchResult>, SubtitleError> {
        let url = format!("{}/api/v1/subtitles/search", self.base_url);
        debug!(url = %url, "subtitle search");
        let resp: SearchResponse = self.send(Method::Post(params), &url).await?;
        Ok(resp
            .subtitles
            .iter()
            .map(SubtitleSearchResult::from_value)
            .collect())
    }

    /// Resolve a `file_id` to its short-lived download URL.
    pub async fn get_download_url(
        &self,
        file_id: &str,
    ) -> Result<DownloadUrlResponse, SubtitleError> {
        let url = format!("{}/api/v1/subtitles/download-url/{file_id}", self.base_url);
        debug!(url = %url, "subtitle download URL");
        self.send::<(), DownloadUrlResponse>(Method::Get, &url)
            .await
    }

    async fn send<B, T>(&self, method: Method<'_, B>, url: &str) -> Result<T, SubtitleError>
    where
        B: Serialize + ?Sized,
        T: for<'de> Deserialize<'de>,
    {
        let mut retry = 0u32;
        loop {
            let req = match &method {
                Method::Post(body) => self.http.post(url).json(*body),
                Method::Get => self.http.get(url),
            };
            let resp = req.send().await;

            let response = match resp {
                Ok(r) => r,
                Err(err) if err.is_timeout() && retry < MAX_RETRIES => {
                    let backoff = backoff_ms(retry);
                    warn!(error = %err, retry, backoff_ms = backoff, "retrying after timeout");
                    tokio::time::sleep(Duration::from_millis(backoff)).await;
                    retry += 1;
                    continue;
                }
                Err(err) => return Err(SubtitleError::from(err)),
            };

            let status = response.status();
            if status.is_success() {
                return response
                    .json::<T>()
                    .await
                    .map_err(|err| SubtitleError::parse(format!("decoding response: {err}")));
            }

            let status_code = status.as_u16();
            match status_code {
                401 | 403 => {
                    return Err(SubtitleError::authentication_failed(format!(
                        "auth failed ({status_code})"
                    )))
                }
                404 => return Err(SubtitleError::not_found("subtitle not found")),
                429 if retry < MAX_RETRIES => {
                    let retry_after = response
                        .headers()
                        .get(reqwest::header::RETRY_AFTER)
                        .and_then(|v| v.to_str().ok())
                        .and_then(|s| s.parse::<u64>().ok())
                        .unwrap_or(1);
                    warn!(retry, retry_after_s = retry_after, "rate limited");
                    tokio::time::sleep(Duration::from_secs(retry_after)).await;
                    retry += 1;
                }
                429 => {
                    return Err(SubtitleError::rate_limited(
                        "rate limited after retries",
                        None,
                    ))
                }
                503 if retry < MAX_RETRIES => {
                    let backoff = backoff_ms(retry);
                    warn!(retry, backoff_ms = backoff, "service unavailable, retrying");
                    tokio::time::sleep(Duration::from_millis(backoff)).await;
                    retry += 1;
                }
                503 => {
                    return Err(SubtitleError::service_unavailable(
                        "still unavailable after retries",
                    ))
                }
                s if s >= 500 && retry < MAX_RETRIES => {
                    let backoff = backoff_ms(retry);
                    warn!(status = s, retry, backoff_ms = backoff, "server error");
                    tokio::time::sleep(Duration::from_millis(backoff)).await;
                    retry += 1;
                }
                other => {
                    error!(status = other, "metadata-relay http error");
                    return Err(SubtitleError::http_error(format!("HTTP {other}"), other));
                }
            }
        }
    }

    /// Download the raw subtitle bytes from the short-lived URL.
    pub async fn download_blob(&self, url: &str) -> Result<Vec<u8>, SubtitleError> {
        let resp = self
            .http
            .get(url)
            .send()
            .await
            .map_err(SubtitleError::from)?;
        if !resp.status().is_success() {
            return Err(SubtitleError::http_error(
                format!("download HTTP {}", resp.status()),
                resp.status().as_u16(),
            ));
        }
        Ok(resp.bytes().await.map_err(SubtitleError::from)?.to_vec())
    }
}

fn backoff_ms(retry: u32) -> u64 {
    INITIAL_BACKOFF_MS * 2_u64.pow(retry)
}

#[async_trait]
impl SubtitleProvider for MetadataRelay {
    async fn search(
        &self,
        _config: &ProviderConfig,
        params: &SearchParams,
    ) -> Result<Vec<SubtitleSearchResult>, SubtitleError> {
        MetadataRelay::search(self, params).await
    }

    async fn download(
        &self,
        _config: &ProviderConfig,
        subtitle: &SubtitleRef,
    ) -> Result<Vec<u8>, SubtitleError> {
        let download = self.get_download_url(&subtitle.file_id).await?;
        self.download_blob(&download.download_url).await
    }

    async fn quota_info(&self, _config: &ProviderConfig) -> Result<QuotaInfo, SubtitleError> {
        // Relay providers are unlimited from the caller's perspective —
        // the relay handles rate-limit accounting upstream.
        Ok(QuotaInfo::unlimited(ProviderKind::Relay))
    }

    async fn validate_config(
        &self,
        _config: &ProviderConfig,
    ) -> Result<serde_json::Value, SubtitleError> {
        // Probe the search endpoint with a no-op query to confirm
        // reachability without consuming quota.
        let probe = SearchParams {
            languages: "en".into(),
            ..SearchParams::default()
        };
        match MetadataRelay::search(self, &probe).await {
            Ok(_) => Ok(serde_json::json!({
                "valid": true,
                "endpoint": self.base_url,
            })),
            Err(err) => Err(err),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn search_returns_parsed_results() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v1/subtitles/search"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "subtitles": [
                    {
                        "file_id": 12345,
                        "language": "en",
                        "format": "srt",
                        "subtitle_hash": "abc",
                        "rating": 8.5,
                        "moviehash_match": true,
                    }
                ]
            })))
            .mount(&server)
            .await;

        let relay = MetadataRelay::new(server.uri()).unwrap();
        let results = relay
            .search(&SearchParams {
                languages: "en".into(),
                imdb_id: Some("816692".into()),
                ..SearchParams::default()
            })
            .await
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].file_id, "12345");
        assert!(results[0].moviehash_match);
    }

    #[tokio::test]
    async fn missing_subtitle_returns_not_found() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/v1/subtitles/download-url/9999"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;

        let relay = MetadataRelay::new(server.uri()).unwrap();
        let err = relay.get_download_url("9999").await.unwrap_err();
        assert_eq!(err.kind, crate::error::SubtitleErrorKind::NotFound);
    }
}
