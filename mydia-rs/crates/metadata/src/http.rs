//! Shared HTTP helpers — Rust port of
//! `lib/mydia/metadata/provider/http.ex`.
//!
//! `reqwest::Client` plays the role of `Req.Request`. The Elixir layer
//! merges auth into the request via `Req.merge(..., headers: ...)` /
//! query-param injection; here we build query params and headers on
//! each call because `reqwest` cloning a `Client` doesn't carry
//! per-request defaults.

use std::time::Duration;

use crate::error::MetadataError;
use crate::provider::ProviderConfig;

/// Default request timeout (matches Elixir's `@default_timeout`).
const DEFAULT_TIMEOUT_MS: u64 = 30_000;

/// User-Agent suffix that lets the metadata-relay see which client is
/// calling. Mirrors the Elixir `"Mydia/<vsn> (<arch>)"` shape; the
/// version pulls in at build time so deployments can be told apart on
/// the relay side without bumping client code.
pub fn user_agent() -> String {
    format!(
        "Mydia-rs/{} ({})",
        env!("CARGO_PKG_VERSION"),
        std::env::consts::ARCH
    )
}

/// Build a `reqwest::Client` configured for a provider.
///
/// Per-call `base_url` joining is handled by [`HttpClient::get`]
/// because `reqwest::Client::builder` doesn't expose a stable base-URL
/// setting; the Elixir layer's `Req.new(base_url: ...)` ergonomics
/// don't translate directly.
pub fn build_client(config: &ProviderConfig) -> Result<reqwest::Client, MetadataError> {
    let timeout_ms = config.option_u64("timeout", DEFAULT_TIMEOUT_MS);
    let connect_timeout_ms = config.option_u64("connect_timeout", 5_000);

    reqwest::Client::builder()
        .user_agent(user_agent())
        .timeout(Duration::from_millis(timeout_ms))
        .connect_timeout(Duration::from_millis(connect_timeout_ms))
        .build()
        .map_err(MetadataError::from)
}

/// HTTP client wrapper that knows the provider's `base_url` and routes
/// every GET through `handle_response`.
#[derive(Debug)]
pub struct HttpClient<'a> {
    inner: reqwest::Client,
    base_url: &'a str,
}

impl<'a> HttpClient<'a> {
    /// Build an [`HttpClient`] from a [`ProviderConfig`].
    pub fn new(config: &'a ProviderConfig) -> Result<Self, MetadataError> {
        if config.base_url.is_empty() {
            return Err(MetadataError::invalid_config("base_url is required"));
        }
        Ok(Self {
            inner: build_client(config)?,
            base_url: &config.base_url,
        })
    }

    /// GET `path` with query parameters. Joins `base_url + path`,
    /// handles auth (API key in query or header), parses JSON, and
    /// maps any non-2xx status into a [`MetadataError`].
    pub async fn get_json<T>(
        &self,
        path: &str,
        params: &[(&str, String)],
        config: &ProviderConfig,
    ) -> Result<T, MetadataError>
    where
        T: serde::de::DeserializeOwned,
    {
        let url = self.join_url(path);

        let mut req = self.inner.get(&url).query(params);

        // Auth: query-param style (default, matches the Elixir default)
        // or bearer / custom header — selected by options.auth_method.
        req = match config.option_str("auth_method", "query") {
            "bearer" => {
                if let Some(key) = &config.api_key {
                    req.bearer_auth(key)
                } else {
                    req
                }
            }
            "header" => {
                if let Some(key) = &config.api_key {
                    let header_name = config.option_str("api_key_header", "x-api-key").to_string();
                    req.header(&header_name, key)
                } else {
                    req
                }
            }
            _ => {
                if let Some(key) = &config.api_key {
                    let param_name = config.option_str("api_key_param", "api_key").to_string();
                    req.query(&[(&param_name, key)])
                } else {
                    req
                }
            }
        };

        let resp = req.send().await.map_err(MetadataError::from)?;
        let status = resp.status();

        if status.is_success() {
            resp.json::<T>().await.map_err(MetadataError::from)
        } else {
            // Try to capture a body excerpt for the error details. If
            // the body isn't UTF-8 we just record the status code.
            let retry_after = retry_after_seconds(&resp);
            let body = resp.text().await.ok();
            Err(MetadataError::from_response_status(
                status.as_u16(),
                retry_after,
                body.as_deref(),
            ))
        }
    }

    /// GET `path` and return the raw JSON value. Used for endpoints
    /// where the shape isn't statically known (TVDB extended series).
    pub async fn get_value(
        &self,
        path: &str,
        params: &[(&str, String)],
        config: &ProviderConfig,
    ) -> Result<serde_json::Value, MetadataError> {
        self.get_json(path, params, config).await
    }

    fn join_url(&self, path: &str) -> String {
        let base = self.base_url.trim_end_matches('/');
        if path.starts_with('/') {
            format!("{base}{path}")
        } else {
            format!("{base}/{path}")
        }
    }
}

fn retry_after_seconds(resp: &reqwest::Response) -> Option<u64> {
    resp.headers()
        .get(reqwest::header::RETRY_AFTER)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse::<u64>().ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn join_url_handles_slashes() {
        let config = ProviderConfig::metadata_relay_default();
        let client = HttpClient::new(&config).unwrap();
        assert_eq!(client.join_url("/foo"), "https://relay.mydia.dev/foo");
        assert_eq!(client.join_url("bar"), "https://relay.mydia.dev/bar");
    }

    #[test]
    fn empty_base_url_is_invalid_config() {
        let mut config = ProviderConfig::metadata_relay_default();
        config.base_url = String::new();
        let err = HttpClient::new(&config).unwrap_err();
        assert_eq!(err.kind, crate::error::ErrorKind::InvalidConfig);
    }
}
