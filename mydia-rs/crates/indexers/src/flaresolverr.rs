//! FlareSolverr HTTP client.
//!
//! Port of `lib/mydia/indexers/flaresolverr.ex`. FlareSolverr proxies
//! requests through a headless browser to clear Cloudflare / DDoS-Guard
//! challenges and returns the resolved HTML plus the challenge cookies.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use tracing::{debug, error, warn};

use crate::error::IndexerError;

const API_PATH: &str = "/v1";

/// Runtime configuration for the FlareSolverr proxy.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlareSolverrConfig {
    /// Whether FlareSolverr is currently in use.
    #[serde(default)]
    pub enabled: bool,
    /// Base URL, e.g. `http://flaresolverr:8191`.
    pub url: String,
    /// Per-request timeout, in milliseconds.
    #[serde(default = "default_timeout_ms")]
    pub timeout_ms: u64,
    /// Hard ceiling FlareSolverr enforces on browser interactions.
    #[serde(default = "default_max_timeout_ms")]
    pub max_timeout_ms: u64,
}

const fn default_timeout_ms() -> u64 {
    60_000
}
const fn default_max_timeout_ms() -> u64 {
    120_000
}

impl FlareSolverrConfig {
    #[must_use]
    pub fn is_usable(&self) -> bool {
        self.enabled && !self.url.is_empty()
    }
}

/// Parsed `solution` block returned by FlareSolverr.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FlareSolverrSolution {
    pub url: Option<String>,
    pub status: Option<u16>,
    #[serde(default)]
    pub cookies: Vec<serde_json::Value>,
    pub user_agent: Option<String>,
    pub response: Option<String>,
    pub headers: Option<serde_json::Value>,
}

/// Full FlareSolverr response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlareSolverrResponse {
    pub status: String,
    pub message: Option<String>,
    pub solution: Option<FlareSolverrSolution>,
    pub start_timestamp: Option<u64>,
    pub end_timestamp: Option<u64>,
    pub version: Option<String>,
}

impl FlareSolverrResponse {
    /// Returns the duration the upstream took to solve the challenge.
    #[must_use]
    pub fn duration_ms(&self) -> Option<u64> {
        Some(self.end_timestamp? - self.start_timestamp?)
    }
}

/// Per-request options. Mirrors the keyword shape used in Elixir.
#[derive(Debug, Default, Clone)]
pub struct RequestOpts {
    pub session: Option<String>,
    pub cookies: Vec<serde_json::Value>,
    pub proxy: Option<String>,
    pub post_data: Option<serde_json::Value>,
    pub timeout_ms: Option<u64>,
    pub max_timeout_ms: Option<u64>,
}

/// FlareSolverr client. Cheap to clone — wraps a `reqwest::Client`.
#[derive(Clone, Debug)]
pub struct FlareSolverr {
    config: FlareSolverrConfig,
    http: reqwest::Client,
}

impl FlareSolverr {
    pub fn new(config: FlareSolverrConfig) -> Result<Self, IndexerError> {
        let http = reqwest::Client::builder()
            .build()
            .map_err(IndexerError::from)?;
        Ok(Self { config, http })
    }

    #[must_use]
    pub fn config(&self) -> &FlareSolverrConfig {
        &self.config
    }

    /// `request.get` over FlareSolverr.
    pub async fn get(
        &self,
        url: &str,
        opts: &RequestOpts,
    ) -> Result<FlareSolverrResponse, IndexerError> {
        self.execute("request.get", url, opts).await
    }

    /// `request.post` over FlareSolverr.
    pub async fn post(
        &self,
        url: &str,
        opts: &RequestOpts,
    ) -> Result<FlareSolverrResponse, IndexerError> {
        self.execute("request.post", url, opts).await
    }

    /// `sessions.list` — used as a lightweight health check.
    pub async fn health_check(&self) -> Result<FlareSolverrResponse, IndexerError> {
        if !self.config.is_usable() {
            return Err(IndexerError::invalid_config(
                "FlareSolverr disabled or unconfigured",
            ));
        }
        let body = serde_json::json!({ "cmd": "sessions.list" });
        self.post_to_flaresolverr(body, Duration::from_millis(5_000))
            .await
    }

    async fn execute(
        &self,
        cmd: &str,
        url: &str,
        opts: &RequestOpts,
    ) -> Result<FlareSolverrResponse, IndexerError> {
        if !self.config.is_usable() {
            return Err(IndexerError::invalid_config(
                "FlareSolverr disabled or unconfigured",
            ));
        }
        let max_timeout = opts.max_timeout_ms.unwrap_or(self.config.max_timeout_ms);
        let mut body = serde_json::json!({
            "cmd": cmd,
            "url": url,
            "maxTimeout": max_timeout,
        });
        if let Some(session) = &opts.session {
            body["session"] = serde_json::Value::from(session.clone());
        }
        if !opts.cookies.is_empty() {
            body["cookies"] = serde_json::Value::from(opts.cookies.clone());
        }
        if let Some(proxy) = &opts.proxy {
            body["proxy"] = serde_json::json!({ "url": proxy });
        }
        if let Some(post_data) = &opts.post_data {
            body["postData"] = post_data.clone();
        }
        debug!(%cmd, %url, "flaresolverr request");

        let timeout = Duration::from_millis(opts.timeout_ms.unwrap_or(self.config.timeout_ms));
        self.post_to_flaresolverr(body, timeout).await
    }

    async fn post_to_flaresolverr(
        &self,
        body: serde_json::Value,
        timeout: Duration,
    ) -> Result<FlareSolverrResponse, IndexerError> {
        let url = format!("{}{}", self.config.url.trim_end_matches('/'), API_PATH);
        let resp = match self
            .http
            .post(&url)
            .timeout(timeout)
            .json(&body)
            .send()
            .await
        {
            Ok(r) => r,
            Err(err) if err.is_timeout() => {
                warn!(error = %err, "flaresolverr timeout");
                return Err(IndexerError::timeout(format!("flaresolverr: {err}")));
            }
            Err(err) => return Err(IndexerError::from(err)),
        };

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.ok();
            error!(status = %status, body = ?body, "flaresolverr http error");
            return Err(IndexerError::from_response_status(
                status.as_u16(),
                None,
                body.as_deref(),
            ));
        }

        let parsed: FlareSolverrResponse = resp
            .json()
            .await
            .map_err(|err| IndexerError::parse_error(format!("flaresolverr: {err}")))?;
        match parsed.status.as_str() {
            "ok" => Ok(parsed),
            "error" => {
                let msg = parsed
                    .message
                    .clone()
                    .unwrap_or_else(|| "flaresolverr error".into());
                warn!(message = %msg, "flaresolverr challenge failed");
                Err(IndexerError::api_error(msg, 200))
            }
            other => Err(IndexerError::unknown(format!(
                "unexpected flaresolverr status: {other}"
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn health_check_succeeds_on_ok_status() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/v1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "status": "ok",
                "version": "3.3.0",
            })))
            .mount(&server)
            .await;

        let fs = FlareSolverr::new(FlareSolverrConfig {
            enabled: true,
            url: server.uri(),
            timeout_ms: 5_000,
            max_timeout_ms: 5_000,
        })
        .unwrap();
        let resp = fs.health_check().await.unwrap();
        assert_eq!(resp.status, "ok");
    }

    #[tokio::test]
    async fn timeout_falls_back_to_error() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/v1"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_delay(Duration::from_millis(200))
                    .set_body_json(serde_json::json!({"status": "ok"})),
            )
            .mount(&server)
            .await;

        let fs = FlareSolverr::new(FlareSolverrConfig {
            enabled: true,
            url: server.uri(),
            timeout_ms: 50,
            max_timeout_ms: 5_000,
        })
        .unwrap();
        let err = fs.get("https://example.com", &RequestOpts::default()).await;
        let err = err.unwrap_err();
        assert_eq!(err.kind, crate::error::ErrorKind::Timeout);
    }

    #[tokio::test]
    async fn disabled_config_rejects_calls() {
        let fs = FlareSolverr::new(FlareSolverrConfig {
            enabled: false,
            url: "http://localhost".into(),
            timeout_ms: 1_000,
            max_timeout_ms: 1_000,
        })
        .unwrap();
        let err = fs.get("https://e.com", &RequestOpts::default()).await;
        assert_eq!(
            err.unwrap_err().kind,
            crate::error::ErrorKind::InvalidConfig
        );
    }
}
