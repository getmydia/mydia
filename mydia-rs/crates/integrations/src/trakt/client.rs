//! HTTP client for Trakt operations via the metadata-relay.
//!
//! Port of `lib/mydia/integrations/trakt/client.ex`. Every request goes
//! through the relay so the Trakt `client_id`/`client_secret` never
//! leave the dev-owned service. User-authenticated endpoints attach the
//! user's access token via the `X-Trakt-User-Token` header.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::error::{ErrorKind, IntegrationError};

const DEFAULT_TIMEOUT_MS: u64 = 30_000;

/// Response shape from `/trakt/oauth/device/code`.
#[derive(Debug, Clone, Deserialize)]
pub struct DeviceCode {
    pub device_code: String,
    pub user_code: String,
    pub verification_url: String,
    pub expires_in: i64,
    pub interval: i64,
}

/// Response shape from `/trakt/oauth/device/token` and
/// `/trakt/oauth/refresh`.
#[derive(Debug, Clone, Deserialize)]
pub struct Token {
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: Option<String>,
    /// Seconds until expiry from the token-issued instant.
    #[serde(default)]
    pub expires_in: Option<i64>,
    #[serde(default)]
    pub created_at: Option<i64>,
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub token_type: Option<String>,
}

/// Sync `type` parameter values. The relay accepts the lowercased
/// names directly; this enum just keeps the call sites typo-proof.
#[derive(Debug, Clone, Copy)]
pub enum SyncKind {
    History,
    Collection,
    Watchlist,
    Ratings,
}

impl SyncKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::History => "history",
            Self::Collection => "collection",
            Self::Watchlist => "watchlist",
            Self::Ratings => "ratings",
        }
    }
}

/// Sync `media_type` parameter values.
#[derive(Debug, Clone, Copy)]
pub enum SyncMediaType {
    Movies,
    Shows,
    Episodes,
}

impl SyncMediaType {
    fn as_str(self) -> &'static str {
        match self {
            Self::Movies => "movies",
            Self::Shows => "shows",
            Self::Episodes => "episodes",
        }
    }
}

/// HTTP client. Cheap to clone (the inner `reqwest::Client` is an
/// `Arc`).
#[derive(Debug, Clone)]
pub struct TraktClient {
    inner: reqwest::Client,
    base_url: String,
}

impl TraktClient {
    /// Build a client pointing at the given metadata-relay base URL.
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

    /// Build a client with a custom `reqwest::Client` (for tests).
    pub fn with_client(base_url: impl Into<String>, inner: reqwest::Client) -> Self {
        Self {
            inner,
            base_url: base_url.into(),
        }
    }

    // ── Device Auth ──────────────────────────────────────────────────

    /// Request a device code (step 1 of the Trakt device flow).
    pub async fn generate_device_code(&self) -> Result<DeviceCode, IntegrationError> {
        self.post_json("/trakt/oauth/device/code", &serde_json::json!({}), None)
            .await
    }

    /// Poll for the device token (step 3 of the Trakt device flow).
    ///
    /// Maps the Trakt-specific HTTP status codes (400/410/418/429) to
    /// dedicated `ErrorKind` variants so callers can drive the polling
    /// loop without re-parsing.
    pub async fn poll_device_token(&self, device_code: &str) -> Result<Token, IntegrationError> {
        let body = serde_json::json!({ "device_code": device_code });
        match self
            .post_json::<Token>("/trakt/oauth/device/token", &body, None)
            .await
        {
            Ok(token) => Ok(token),
            Err(err) => Err(map_device_poll_error(err)),
        }
    }

    // ── OAuth ────────────────────────────────────────────────────────

    /// Refresh an expired token via the relay.
    pub async fn refresh_token(&self, refresh_token: &str) -> Result<Token, IntegrationError> {
        let body = serde_json::json!({ "refresh_token": refresh_token });
        self.post_json("/trakt/oauth/refresh", &body, None).await
    }

    /// Revoke a token via the relay. Returns the raw JSON body so the
    /// caller can log the relay's confirmation, but the value is
    /// rarely interesting.
    pub async fn revoke_token(&self, token: &str) -> Result<serde_json::Value, IntegrationError> {
        let body = serde_json::json!({ "token": token });
        self.post_json("/trakt/oauth/revoke", &body, None).await
    }

    // ── Scrobble ─────────────────────────────────────────────────────

    pub async fn scrobble_start(
        &self,
        body: &serde_json::Value,
        user_token: &str,
    ) -> Result<serde_json::Value, IntegrationError> {
        self.post_json("/trakt/scrobble/start", body, Some(user_token))
            .await
    }

    pub async fn scrobble_pause(
        &self,
        body: &serde_json::Value,
        user_token: &str,
    ) -> Result<serde_json::Value, IntegrationError> {
        self.post_json("/trakt/scrobble/pause", body, Some(user_token))
            .await
    }

    pub async fn scrobble_stop(
        &self,
        body: &serde_json::Value,
        user_token: &str,
    ) -> Result<serde_json::Value, IntegrationError> {
        self.post_json("/trakt/scrobble/stop", body, Some(user_token))
            .await
    }

    // ── Sync ─────────────────────────────────────────────────────────

    /// `GET /trakt/sync/<type>/<media_type>` with optional `start_at`
    /// query parameter.
    pub async fn get_sync(
        &self,
        kind: SyncKind,
        media_type: SyncMediaType,
        user_token: &str,
        start_at: Option<&str>,
    ) -> Result<serde_json::Value, IntegrationError> {
        let path = format!("/trakt/sync/{}/{}", kind.as_str(), media_type.as_str());
        let params: Vec<(&str, String)> = match start_at {
            Some(s) => vec![("start_at", s.to_owned())],
            None => Vec::new(),
        };
        self.get_json(&path, &params, Some(user_token)).await
    }

    /// `POST /trakt/sync/<type>` — bulk add to the user's history /
    /// collection / watchlist.
    pub async fn add_sync(
        &self,
        kind: SyncKind,
        body: &serde_json::Value,
        user_token: &str,
    ) -> Result<serde_json::Value, IntegrationError> {
        let path = format!("/trakt/sync/{}", kind.as_str());
        self.post_json(&path, body, Some(user_token)).await
    }

    /// `POST /trakt/sync/<type>/remove`.
    pub async fn remove_sync(
        &self,
        kind: SyncKind,
        body: &serde_json::Value,
        user_token: &str,
    ) -> Result<serde_json::Value, IntegrationError> {
        let path = format!("/trakt/sync/{}/remove", kind.as_str());
        self.post_json(&path, body, Some(user_token)).await
    }

    // ── Internals ────────────────────────────────────────────────────

    async fn get_json<T: serde::de::DeserializeOwned>(
        &self,
        path: &str,
        params: &[(&str, String)],
        user_token: Option<&str>,
    ) -> Result<T, IntegrationError> {
        let url = self.join(path);
        let mut req = self.inner.get(&url).query(params);
        req = apply_user_token(req, user_token);
        let resp = req.send().await.map_err(|err| {
            warn!(method = "GET", %path, "Trakt relay request failed");
            IntegrationError::from(err)
        })?;
        decode_json_response(resp).await
    }

    async fn post_json<T: serde::de::DeserializeOwned>(
        &self,
        path: &str,
        body: &serde_json::Value,
        user_token: Option<&str>,
    ) -> Result<T, IntegrationError> {
        let url = self.join(path);
        let mut req = self.inner.post(&url).json(body);
        req = apply_user_token(req, user_token);
        let resp = req.send().await.map_err(|err| {
            warn!(method = "POST", %path, "Trakt relay request failed");
            IntegrationError::from(err)
        })?;
        decode_json_response(resp).await
    }

    fn join(&self, path: &str) -> String {
        let base = self.base_url.trim_end_matches('/');
        if path.starts_with('/') {
            format!("{base}{path}")
        } else {
            format!("{base}/{path}")
        }
    }
}

fn apply_user_token(
    req: reqwest::RequestBuilder,
    user_token: Option<&str>,
) -> reqwest::RequestBuilder {
    match user_token {
        Some(token) => req.header("x-trakt-user-token", token),
        None => req,
    }
}

async fn decode_json_response<T: serde::de::DeserializeOwned>(
    resp: reqwest::Response,
) -> Result<T, IntegrationError> {
    let status = resp.status();
    if status.is_success() {
        resp.json::<T>().await.map_err(IntegrationError::from)
    } else {
        let retry_after = resp
            .headers()
            .get(reqwest::header::RETRY_AFTER)
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.parse::<u64>().ok());
        let body = resp.text().await.ok();
        Err(IntegrationError::from_response_status(
            status.as_u16(),
            retry_after,
            body.as_deref(),
        ))
    }
}

/// Map device-poll HTTP errors to dedicated kinds. The relay surfaces
/// the underlying Trakt status codes verbatim:
///
/// - `400` — pending (user hasn't entered the code yet)
/// - `410` — expired
/// - `418` — denied
/// - `429` — slow down
fn map_device_poll_error(err: IntegrationError) -> IntegrationError {
    match err.status {
        Some(400) => IntegrationError::new(ErrorKind::DevicePending, "device flow pending"),
        Some(410) => IntegrationError::new(ErrorKind::DeviceExpired, "device flow expired"),
        Some(418) => IntegrationError::new(ErrorKind::DeviceDenied, "device flow denied"),
        Some(429) => IntegrationError::new(ErrorKind::DeviceSlowDown, "device flow slow down"),
        _ => err,
    }
}

/// Build a serializable `ids` map for an item with optional external
/// IDs. The result is suitable as the `ids` field of a Trakt movie /
/// show payload — returns `None` when no IDs were supplied so callers
/// can short-circuit empty pushes.
#[must_use]
pub fn build_ids(
    imdb: Option<&str>,
    tmdb: Option<&str>,
    tvdb: Option<&str>,
) -> Option<serde_json::Map<String, serde_json::Value>> {
    let mut map = serde_json::Map::new();
    if let Some(v) = imdb {
        map.insert("imdb".into(), serde_json::Value::String(v.to_owned()));
    }
    if let Some(v) = tmdb {
        map.insert("tmdb".into(), serde_json::Value::String(v.to_owned()));
    }
    if let Some(v) = tvdb {
        map.insert("tvdb".into(), serde_json::Value::String(v.to_owned()));
    }
    if map.is_empty() {
        None
    } else {
        Some(map)
    }
}

/// Build a Trakt movie payload (`ids`, `title`, `year`, `watched_at`).
/// Used by both history-push and collection-push call sites.
#[derive(Debug, Clone, Serialize)]
pub struct TraktMoviePayload {
    pub ids: serde_json::Map<String, serde_json::Value>,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub year: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub watched_at: Option<String>,
}

/// Build a Trakt show payload (`ids`, `title`, `year`).
#[derive(Debug, Clone, Serialize)]
pub struct TraktShowPayload {
    pub ids: serde_json::Map<String, serde_json::Value>,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub year: Option<i32>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_base_url_is_invalid_config() {
        let err = TraktClient::new("").unwrap_err();
        assert_eq!(err.kind, ErrorKind::InvalidConfig);
    }

    #[test]
    fn build_ids_returns_none_when_all_missing() {
        assert!(build_ids(None, None, None).is_none());
    }

    #[test]
    fn build_ids_collects_only_provided_keys() {
        let ids = build_ids(Some("tt1234"), None, Some("9999")).unwrap();
        assert_eq!(ids.get("imdb").unwrap(), "tt1234");
        assert_eq!(ids.get("tvdb").unwrap(), "9999");
        assert!(ids.get("tmdb").is_none());
    }

    #[test]
    fn sync_kind_as_str_matches_relay_routes() {
        assert_eq!(SyncKind::History.as_str(), "history");
        assert_eq!(SyncKind::Collection.as_str(), "collection");
        assert_eq!(SyncMediaType::Movies.as_str(), "movies");
        assert_eq!(SyncMediaType::Episodes.as_str(), "episodes");
    }
}
