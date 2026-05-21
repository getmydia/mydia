//! `Provider` trait — Rust port of the `Mydia.Metadata.Provider`
//! Elixir behaviour.
//!
//! Implementors: [`crate::relay::Relay`], [`crate::open_library::OpenLibrary`].
//!
//! The trait is `async` and dyn-compatible via [`async_trait`]. The
//! plan calls for "stable async fn in traits" but stable async fn in
//! traits (Rust 1.75+) does **not** produce dyn-compatible methods, so
//! storing `Box<dyn Provider>` in the registry still requires the
//! `async_trait` macro at the impl boundary. Workspace toolchain is
//! 1.94, so the macro overhead is purely an ergonomics tradeoff.

use crate::error::MetadataError;
use crate::structs::{
    ConnectionInfo, ImagesResponse, MediaMetadata, MediaType, SearchResult, SeasonData,
};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};

/// Provider configuration — equivalent to the Elixir `config` map.
///
/// Adapters typically only consume `base_url` plus a handful of
/// `options.*` fields; the broader struct exists so the same config
/// can drive every adapter without per-provider boilerplate.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderConfig {
    /// Discriminant for which adapter handles this config. Mirrors the
    /// Elixir `:type` field; used by the registry to route by kind.
    pub r#type: String,
    /// API key, if the provider needs one. The default metadata-relay
    /// deployment doesn't.
    pub api_key: Option<String>,
    /// Endpoint root, e.g. `https://relay.mydia.dev`.
    pub base_url: String,
    /// Free-form options (`language`, `include_adult`, `timeout_ms`,
    /// `auth_method`, ...). Carried as JSON for parity with Elixir's
    /// `map()` shape.
    #[serde(default)]
    pub options: serde_json::Value,
}

impl ProviderConfig {
    /// Construct a config for the default metadata-relay endpoint.
    #[must_use]
    pub fn metadata_relay_default() -> Self {
        Self {
            r#type: "metadata_relay".into(),
            api_key: None,
            base_url: "https://relay.mydia.dev".into(),
            options: serde_json::json!({
                "language": "en-US",
                "include_adult": false,
            }),
        }
    }

    /// Read a string field from `options`, falling back to `default`.
    #[must_use]
    pub fn option_str<'a>(&'a self, key: &str, default: &'a str) -> &'a str {
        self.options
            .get(key)
            .and_then(serde_json::Value::as_str)
            .unwrap_or(default)
    }

    /// Read a `bool` field from `options`, falling back to `default`.
    #[must_use]
    pub fn option_bool(&self, key: &str, default: bool) -> bool {
        self.options
            .get(key)
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(default)
    }

    /// Read a `u64` field from `options`, falling back to `default`.
    #[must_use]
    pub fn option_u64(&self, key: &str, default: u64) -> u64 {
        self.options
            .get(key)
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(default)
    }
}

/// Options accepted by [`Provider::search`].
#[derive(Debug, Clone, Default)]
pub struct SearchOpts {
    pub media_type: Option<MediaType>,
    pub year: Option<i32>,
    pub language: Option<String>,
    pub include_adult: Option<bool>,
    pub page: Option<u32>,
}

/// Options accepted by [`Provider::fetch_by_id`].
#[derive(Debug, Clone, Default)]
pub struct FetchOpts {
    /// When omitted, adapters default to `MediaType::Movie`.
    pub media_type: Option<MediaType>,
    pub language: Option<String>,
    /// Explicit provider override (`:tmdb` vs `:tvdb` in Elixir).
    /// `None` lets the relay pick by `media_type`.
    pub provider: Option<&'static str>,
    /// Mirrors TMDB's `append_to_response`. Adapters that don't
    /// recognize the parameter ignore it.
    pub append_to_response: Vec<String>,
}

/// Options accepted by [`Provider::fetch_images`].
#[derive(Debug, Clone, Default)]
pub struct ImageOpts {
    pub media_type: Option<MediaType>,
    pub provider: Option<&'static str>,
    pub language: Option<String>,
    pub include_image_language: Option<String>,
}

/// Options accepted by [`Provider::fetch_season`].
#[derive(Debug, Clone, Default)]
pub struct SeasonOpts {
    pub language: Option<String>,
    /// When set, the relay queries TVDB by season ID instead of
    /// (`provider_id`, `season_number`).
    pub tvdb_season_id: Option<i64>,
}

/// Options accepted by [`Provider::fetch_trending`].
#[derive(Debug, Clone, Default)]
pub struct TrendingOpts {
    pub media_type: Option<MediaType>,
    pub language: Option<String>,
    pub page: Option<u32>,
}

/// The provider behaviour. Every adapter implements every method;
/// adapters that don't support a feature return
/// [`MetadataError::invalid_request`] rather than ad-hoc panics. This
/// matches the Elixir behaviour callbacks which all return
/// `{:ok, _} | {:error, _}`.
#[async_trait]
pub trait Provider: Send + Sync {
    /// Probe the upstream. Returns a small struct rather than the
    /// free-form map the Elixir behaviour returns; the only call
    /// sites read `status` and `provider`.
    async fn test_connection(
        &self,
        config: &ProviderConfig,
    ) -> Result<ConnectionInfo, MetadataError>;

    /// Search for media by query string.
    async fn search(
        &self,
        config: &ProviderConfig,
        query: &str,
        opts: &SearchOpts,
    ) -> Result<Vec<SearchResult>, MetadataError>;

    /// Fetch full metadata for a known provider ID.
    async fn fetch_by_id(
        &self,
        config: &ProviderConfig,
        provider_id: &str,
        opts: &FetchOpts,
    ) -> Result<MediaMetadata, MetadataError>;

    /// Fetch poster / backdrop / logo collections.
    async fn fetch_images(
        &self,
        config: &ProviderConfig,
        provider_id: &str,
        opts: &ImageOpts,
    ) -> Result<ImagesResponse, MetadataError>;

    /// Fetch season + episode data. For TVDB adapters, set
    /// `opts.tvdb_season_id` to query by season ID directly.
    async fn fetch_season(
        &self,
        config: &ProviderConfig,
        provider_id: &str,
        season_number: i32,
        opts: &SeasonOpts,
    ) -> Result<SeasonData, MetadataError>;

    /// Fetch trending media for browse pages.
    async fn fetch_trending(
        &self,
        config: &ProviderConfig,
        opts: &TrendingOpts,
    ) -> Result<Vec<SearchResult>, MetadataError>;
}
