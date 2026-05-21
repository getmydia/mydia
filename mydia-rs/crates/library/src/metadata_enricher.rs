//! Orchestrates [`Provider`] calls against the metadata-relay to
//! fetch full metadata for a matched media item.
//!
//! Port of `lib/mydia/library/metadata_enricher.ex` — only the
//! provider-side interactions live here. The Phoenix module also
//! writes to the `media_items` / `episodes` tables; that side is
//! deliberately deferred to U17, which has the worker context and
//! transaction boundary to do it well.
//!
//! The exposed surface focuses on the fetch step: given a matched
//! provider id + media type, [`MetadataEnricher::fetch_full`]
//! returns the consolidated metadata payload plus (for TV shows)
//! per-season episode data.
//!
//! [`Provider`]: mydia_rs_metadata::Provider

use std::sync::Arc;

use mydia_rs_metadata::{
    FetchOpts, MediaMetadata, MediaType, Provider, ProviderConfig, SeasonData, SeasonOpts,
};

use crate::error::LibraryError;

/// Input to [`MetadataEnricher::fetch_full`].
#[derive(Debug, Clone)]
pub struct EnrichInput {
    pub provider_id: String,
    pub media_type: MediaType,
    /// When `true` (and `media_type == TvShow`), also fetch
    /// per-season episode data for every season exposed in the
    /// movie/show metadata.
    pub fetch_episodes: bool,
    /// Language override — mirrors the Elixir
    /// `Keyword.get(opts, :language)` plumbed through every
    /// provider call.
    pub language: Option<String>,
}

/// Result of a full enrichment.
#[derive(Debug, Clone)]
pub struct EnrichResult {
    pub metadata: MediaMetadata,
    /// Per-season episode data — empty for movies, populated for
    /// TV shows when `fetch_episodes` was `true`.
    pub seasons: Vec<SeasonData>,
}

/// Public facade.
#[derive(Clone)]
pub struct MetadataEnricher {
    provider: Arc<dyn Provider>,
    config: ProviderConfig,
}

impl MetadataEnricher {
    /// Build an enricher with the supplied provider and config.
    #[must_use]
    pub fn new(provider: Arc<dyn Provider>, config: ProviderConfig) -> Self {
        Self { provider, config }
    }

    /// Fetch full metadata for a media item.
    pub async fn fetch_full(&self, input: EnrichInput) -> Result<EnrichResult, LibraryError> {
        let fetch_opts = FetchOpts {
            media_type: Some(input.media_type),
            language: input.language.clone(),
            ..FetchOpts::default()
        };

        let metadata = self
            .provider
            .fetch_by_id(&self.config, &input.provider_id, &fetch_opts)
            .await?;

        let seasons = if matches!(input.media_type, MediaType::TvShow) && input.fetch_episodes {
            self.fetch_all_seasons(&input.provider_id, input.language.as_deref(), &metadata)
                .await?
        } else {
            Vec::new()
        };

        Ok(EnrichResult { metadata, seasons })
    }

    async fn fetch_all_seasons(
        &self,
        provider_id: &str,
        language: Option<&str>,
        metadata: &MediaMetadata,
    ) -> Result<Vec<SeasonData>, LibraryError> {
        let mut out = Vec::new();
        for season in &metadata.seasons {
            // Skip season 0 (specials) by default — Phoenix's enricher
            // takes the same shortcut.
            if season.season_number == 0 {
                continue;
            }
            let opts = SeasonOpts {
                language: language.map(str::to_owned),
                tvdb_season_id: season.tvdb_season_id,
            };
            match self
                .provider
                .fetch_season(&self.config, provider_id, season.season_number, &opts)
                .await
            {
                Ok(data) => out.push(data),
                Err(err) => {
                    tracing::warn!(
                        provider_id = provider_id,
                        season = season.season_number,
                        error = %err,
                        "season fetch failed; continuing",
                    );
                }
            }
        }
        Ok(out)
    }
}

impl std::fmt::Debug for MetadataEnricher {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // `provider` is `dyn Provider` — not `Debug` — so we render
        // the config fields the caller can verify.
        f.debug_struct("MetadataEnricher")
            .field("provider", &"<dyn Provider>")
            .field("base_url", &self.config.base_url)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use mydia_rs_metadata::{
        ConnectionInfo, ImagesResponse, ProviderKind, SearchOpts, SearchResult, TrendingOpts,
    };

    struct StubProvider;

    #[async_trait]
    impl Provider for StubProvider {
        async fn test_connection(
            &self,
            _config: &ProviderConfig,
        ) -> Result<ConnectionInfo, mydia_rs_metadata::MetadataError> {
            unreachable!()
        }

        async fn search(
            &self,
            _config: &ProviderConfig,
            _query: &str,
            _opts: &SearchOpts,
        ) -> Result<Vec<SearchResult>, mydia_rs_metadata::MetadataError> {
            Ok(Vec::new())
        }

        async fn fetch_by_id(
            &self,
            _config: &ProviderConfig,
            _provider_id: &str,
            _opts: &FetchOpts,
        ) -> Result<MediaMetadata, mydia_rs_metadata::MetadataError> {
            Ok(stub_metadata(MediaType::Movie))
        }

        async fn fetch_images(
            &self,
            _config: &ProviderConfig,
            _provider_id: &str,
            _opts: &mydia_rs_metadata::ImageOpts,
        ) -> Result<ImagesResponse, mydia_rs_metadata::MetadataError> {
            Ok(ImagesResponse::default())
        }

        async fn fetch_season(
            &self,
            _config: &ProviderConfig,
            _provider_id: &str,
            _season_number: i32,
            _opts: &SeasonOpts,
        ) -> Result<SeasonData, mydia_rs_metadata::MetadataError> {
            Ok(SeasonData {
                season_number: 1,
                name: None,
                overview: None,
                air_date: None,
                poster_path: None,
                episode_count: Some(0),
                episodes: Vec::new(),
            })
        }

        async fn fetch_trending(
            &self,
            _config: &ProviderConfig,
            _opts: &TrendingOpts,
        ) -> Result<Vec<SearchResult>, mydia_rs_metadata::MetadataError> {
            Ok(Vec::new())
        }
    }

    fn stub_metadata(media_type: MediaType) -> MediaMetadata {
        MediaMetadata {
            provider_id: "1".into(),
            provider: ProviderKind::MetadataRelay,
            media_type,
            id: None,
            title: Some("Stub".into()),
            original_title: None,
            year: None,
            release_date: None,
            overview: None,
            tagline: None,
            runtime: None,
            status: None,
            genres: Vec::new(),
            poster_path: None,
            backdrop_path: None,
            popularity: None,
            vote_average: None,
            vote_count: None,
            imdb_id: None,
            production_companies: Vec::new(),
            production_countries: Vec::new(),
            spoken_languages: Vec::new(),
            homepage: None,
            cast: Vec::new(),
            crew: Vec::new(),
            alternative_titles: Vec::new(),
            videos: Vec::new(),
            origin_country: Vec::new(),
            original_language: None,
            number_of_seasons: None,
            number_of_episodes: None,
            episode_run_time: Vec::new(),
            first_air_date: None,
            last_air_date: None,
            in_production: None,
            seasons: Vec::new(),
        }
    }

    #[tokio::test]
    async fn fetch_full_movie_returns_metadata_no_seasons() {
        let enricher = MetadataEnricher::new(
            Arc::new(StubProvider),
            ProviderConfig::metadata_relay_default(),
        );
        let result = enricher
            .fetch_full(EnrichInput {
                provider_id: "1".into(),
                media_type: MediaType::Movie,
                fetch_episodes: true,
                language: None,
            })
            .await
            .unwrap();
        assert!(result.seasons.is_empty());
        assert_eq!(result.metadata.title.as_deref(), Some("Stub"));
    }
}
