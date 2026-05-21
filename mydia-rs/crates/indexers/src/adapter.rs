//! `IndexerAdapter` trait.
//!
//! Rust port of `lib/mydia/indexers/adapter.ex` (the behaviour) plus the
//! `adapter/cardigann.ex`, `adapter/jackett.ex`, `adapter/prowlarr.ex`,
//! and `adapter/nzbhydra2.ex` implementations. The U17 worker layer
//! takes `Arc<dyn IndexerAdapter>` so individual concrete adapters
//! can be swapped per search request without touching the worker.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::error::IndexerError;
use crate::search_result::SearchResult;

/// Adapter discriminant — mirrors the Elixir `:type` atom.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AdapterKind {
    Cardigann,
    Prowlarr,
    Jackett,
    Nzbhydra2,
}

/// User-provided configuration for an adapter instance.
///
/// Stored in the database (`indexer_configs` table) as a single JSON
/// blob; deserializes into this struct via `serde`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdapterConfig {
    pub r#type: AdapterKind,
    pub name: String,
    pub base_url: String,
    pub api_key: Option<String>,
    #[serde(default)]
    pub options: serde_json::Value,
    /// Stable internal identifier used by the rate limiter, the health
    /// cache, and the registry.
    pub id: String,
    /// Optional per-indexer rate limit (requests / minute).
    pub rate_limit: Option<u32>,
}

/// Per-search options passed by the worker layer.
#[derive(Debug, Clone, Default)]
pub struct SearchOpts {
    /// Newznab category IDs.
    pub categories: Vec<i32>,
    /// Soft cap on returned rows.
    pub limit: Option<u32>,
    /// IMDB ID for ID-based search.
    pub imdb_id: Option<String>,
    /// TMDB ID for ID-based search.
    pub tmdb_id: Option<i64>,
    /// TVDB ID for ID-based search.
    pub tvdb_id: Option<i64>,
    /// Season number for TV-only searches.
    pub season: Option<i32>,
    /// Episode number for TV-only searches.
    pub episode: Option<i32>,
}

/// Capabilities returned by [`IndexerAdapter::capabilities`].
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Capabilities {
    pub searching: SearchingCapabilities,
    pub categories: Vec<CategoryDescriptor>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SearchingCapabilities {
    pub search: CapabilityMode,
    pub tv_search: CapabilityMode,
    pub movie_search: CapabilityMode,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CapabilityMode {
    #[serde(default)]
    pub available: bool,
    #[serde(default)]
    pub supported_params: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CategoryDescriptor {
    pub id: i32,
    pub name: String,
}

/// Connection-probe payload returned by [`IndexerAdapter::test_connection`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectionInfo {
    pub name: Option<String>,
    pub version: Option<String>,
    pub details: serde_json::Value,
}

/// The adapter behaviour. Every implementation lives in this crate or
/// in U17 (downloads/jobs may add wrappers). `async_trait` is required
/// because the registry stores `Arc<dyn IndexerAdapter>`.
#[async_trait]
pub trait IndexerAdapter: Send + Sync {
    /// Verify connectivity + credentials.
    async fn test_connection(&self, config: &AdapterConfig)
        -> Result<ConnectionInfo, IndexerError>;

    /// Search the indexer. Returns the raw `SearchResult` list — the
    /// caller applies filtering / ranking via [`crate::release_ranker`].
    async fn search(
        &self,
        config: &AdapterConfig,
        query: &str,
        opts: &SearchOpts,
    ) -> Result<Vec<SearchResult>, IndexerError>;

    /// Per-indexer capabilities (search modes + categories).
    async fn capabilities(&self, config: &AdapterConfig) -> Result<Capabilities, IndexerError>;
}
