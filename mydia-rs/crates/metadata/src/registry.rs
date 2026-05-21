//! Registry of metadata provider adapters.
//!
//! Mirrors `lib/mydia/metadata/provider/registry.ex` (which is an
//! `Agent` keyed by provider atom) but in a single owned struct that's
//! constructed at boot rather than mutated at runtime. The plan
//! describes the registry as "built at app startup from Config + DB-
//! stored `provider_priority` setting" — the DB-read side is the
//! responsibility of U17/U28 (settings loading), so this crate exposes
//! a builder that accepts a pre-resolved priority order.
//!
//! ## Ordering
//!
//! [`ProviderRegistry::iter_in_priority`] yields adapters in the order
//! the caller passed at construction time. The fallback semantic in
//! Elixir (try first provider, fall back to next on `:not_found`) is
//! implemented by [`ProviderRegistry::search_with_fallback`] et al.

use std::collections::HashMap;
use std::sync::Arc;

use crate::error::MetadataError;
use crate::provider::{Provider, ProviderConfig, SearchOpts};
use crate::structs::SearchResult;

/// A single (kind, adapter, config) tuple. Adapters carry no state of
/// their own; configuration is per-entry so the same Rust struct can
/// back multiple registry entries (e.g., a self-hosted and a public
/// metadata-relay deployment).
pub struct RegisteredProvider {
    /// Provider atom from the Elixir taxonomy (`tmdb`, `tvdb`,
    /// `metadata_relay`, `open_library`, ...). Stored as `&'static str`
    /// because the registry is fixed at boot.
    pub kind: &'static str,
    /// The trait object. `Arc` so callers can clone-and-spawn without
    /// caring about lifetimes.
    pub adapter: Arc<dyn Provider>,
    /// Per-entry config.
    pub config: ProviderConfig,
}

/// Registry of configured providers in priority order.
///
/// Constructed via [`ProviderRegistry::new`] with a `Vec<RegisteredProvider>`
/// arranged from highest to lowest priority. The DB-side
/// `provider_priority` setting is read in U17/U28; for now callers
/// pass their preferred order directly.
pub struct ProviderRegistry {
    by_priority: Vec<RegisteredProvider>,
    by_kind: HashMap<&'static str, usize>,
}

impl ProviderRegistry {
    /// Build a registry from an ordered list of entries.
    ///
    /// If two entries share a `kind`, the lower-priority one wins for
    /// [`Self::get`] lookups — `by_kind` is built by iterating in
    /// priority order and only inserting the first occurrence.
    #[must_use]
    pub fn new(entries: Vec<RegisteredProvider>) -> Self {
        let mut by_kind = HashMap::with_capacity(entries.len());
        for (i, entry) in entries.iter().enumerate() {
            by_kind.entry(entry.kind).or_insert(i);
        }
        Self {
            by_priority: entries,
            by_kind,
        }
    }

    /// Empty registry; useful for tests and for the U17 worker layer
    /// before priority loading completes.
    #[must_use]
    pub fn empty() -> Self {
        Self::new(Vec::new())
    }

    /// Number of registered providers.
    #[must_use]
    pub fn len(&self) -> usize {
        self.by_priority.len()
    }

    /// True when no providers are registered.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.by_priority.is_empty()
    }

    /// Iterate over registered providers in priority order.
    pub fn iter_in_priority(&self) -> impl Iterator<Item = &RegisteredProvider> {
        self.by_priority.iter()
    }

    /// Get an adapter by its kind atom. Returns the highest-priority
    /// entry for that kind, matching the Elixir registry's
    /// `get_provider/1` semantics.
    #[must_use]
    pub fn get(&self, kind: &str) -> Option<&RegisteredProvider> {
        self.by_kind.get(kind).map(|&i| &self.by_priority[i])
    }

    /// Search via the highest-priority provider, falling back to the
    /// next on `NotFound`. Other errors short-circuit. Matches the
    /// fallback semantic the Elixir `Mydia.Metadata` context module
    /// applies on top of the registry today.
    pub async fn search_with_fallback(
        &self,
        query: &str,
        opts: &SearchOpts,
    ) -> Result<Vec<SearchResult>, MetadataError> {
        if self.by_priority.is_empty() {
            return Err(MetadataError::invalid_config(
                "no metadata providers configured",
            ));
        }

        let mut last_err: Option<MetadataError> = None;
        for entry in &self.by_priority {
            match entry.adapter.search(&entry.config, query, opts).await {
                Ok(results) if !results.is_empty() => return Ok(results),
                Ok(empty) => {
                    last_err = Some(MetadataError::not_found(format!(
                        "no results for query: {query}"
                    )));
                    // Allow next provider a chance; preserve last_err.
                    let _ = empty;
                }
                Err(err) if err.kind == crate::error::ErrorKind::NotFound => {
                    last_err = Some(err);
                }
                Err(err) => return Err(err),
            }
        }
        Err(last_err
            .unwrap_or_else(|| MetadataError::not_found(format!("no results for query: {query}"))))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::MetadataError;
    use crate::provider::{FetchOpts, ImageOpts, ProviderConfig, SeasonOpts, TrendingOpts};
    use crate::structs::{ConnectionInfo, ImagesResponse, MediaMetadata, SeasonData};
    use async_trait::async_trait;

    /// Test stub — always returns a single-result search, returns
    /// `NotFound` for everything else.
    struct StubProvider {
        kind: &'static str,
    }

    #[async_trait]
    impl Provider for StubProvider {
        async fn test_connection(
            &self,
            _config: &ProviderConfig,
        ) -> Result<ConnectionInfo, MetadataError> {
            Ok(ConnectionInfo {
                status: "ok".into(),
                provider: self.kind.into(),
            })
        }

        async fn search(
            &self,
            _config: &ProviderConfig,
            query: &str,
            _opts: &SearchOpts,
        ) -> Result<Vec<SearchResult>, MetadataError> {
            if query == "hit" {
                Ok(vec![SearchResult {
                    provider_id: "1".into(),
                    provider: crate::structs::ProviderKind::MetadataRelay,
                    media_type: crate::structs::MediaType::Movie,
                    title: Some("hit".into()),
                    name: None,
                    original_title: None,
                    original_name: None,
                    year: None,
                    release_date: None,
                    first_air_date: None,
                    poster_path: None,
                    backdrop_path: None,
                    id: None,
                    imdb_id: None,
                    overview: None,
                    popularity: None,
                    vote_average: None,
                    vote_count: None,
                }])
            } else {
                Err(MetadataError::not_found("no match"))
            }
        }

        async fn fetch_by_id(
            &self,
            _config: &ProviderConfig,
            _provider_id: &str,
            _opts: &FetchOpts,
        ) -> Result<MediaMetadata, MetadataError> {
            Err(MetadataError::not_found("stub"))
        }

        async fn fetch_images(
            &self,
            _config: &ProviderConfig,
            _provider_id: &str,
            _opts: &ImageOpts,
        ) -> Result<ImagesResponse, MetadataError> {
            Ok(ImagesResponse::default())
        }

        async fn fetch_season(
            &self,
            _config: &ProviderConfig,
            _provider_id: &str,
            _season_number: i32,
            _opts: &SeasonOpts,
        ) -> Result<SeasonData, MetadataError> {
            Err(MetadataError::not_found("stub"))
        }

        async fn fetch_trending(
            &self,
            _config: &ProviderConfig,
            _opts: &TrendingOpts,
        ) -> Result<Vec<SearchResult>, MetadataError> {
            Ok(vec![])
        }
    }

    fn entry(kind: &'static str) -> RegisteredProvider {
        RegisteredProvider {
            kind,
            adapter: Arc::new(StubProvider { kind }),
            config: ProviderConfig::metadata_relay_default(),
        }
    }

    #[tokio::test]
    async fn iter_yields_priority_order() {
        let registry = ProviderRegistry::new(vec![entry("tmdb"), entry("tvdb")]);
        let kinds: Vec<_> = registry.iter_in_priority().map(|e| e.kind).collect();
        assert_eq!(kinds, vec!["tmdb", "tvdb"]);
    }

    #[tokio::test]
    async fn get_returns_first_match_by_kind() {
        let registry = ProviderRegistry::new(vec![entry("tmdb"), entry("tvdb")]);
        assert!(registry.get("tmdb").is_some());
        assert!(registry.get("nope").is_none());
    }

    #[tokio::test]
    async fn search_falls_back_on_not_found() {
        let registry = ProviderRegistry::new(vec![entry("tmdb"), entry("tvdb")]);
        let results = registry
            .search_with_fallback("hit", &SearchOpts::default())
            .await
            .unwrap();
        assert_eq!(results.len(), 1);

        let err = registry
            .search_with_fallback("miss", &SearchOpts::default())
            .await
            .unwrap_err();
        assert_eq!(err.kind, crate::error::ErrorKind::NotFound);
    }

    #[tokio::test]
    async fn empty_registry_returns_invalid_config() {
        let registry = ProviderRegistry::empty();
        let err = registry
            .search_with_fallback("x", &SearchOpts::default())
            .await
            .unwrap_err();
        assert_eq!(err.kind, crate::error::ErrorKind::InvalidConfig);
    }
}
