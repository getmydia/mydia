//! Discover page server functions (U24.f).
//!
//! Minimal shell around `mydia_rs_metadata::Relay::fetch_curated`. The
//! Phoenix `DiscoverLive.Index` accepts a full filter set (genre, year,
//! original-language, sort, vote-average); this U24.f surface keeps
//! the form small: media-type toggle (movies vs tv), category, and
//! language. Richer filters (genre + year + sort) come in a follow-up
//! once the genre catalogue is plumbed through (`/tmdb/movies/genres`
//! endpoint, not yet wrapped in the Rust client).
//!
//! The metadata-relay base URL is the default
//! `https://relay.mydia.dev`. Operator-configurable URL via
//! `mydia.toml` is also a follow-up; the config crate doesn't carry
//! that field yet.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Wire payload for the discover-page request — what the form drives.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiscoverQuery {
    /// `"movie"` or `"tv_show"`. Mirrors `MediaType` from the
    /// metadata crate's serde encoding; passed as a string so the
    /// page doesn't take a dep on `mydia_rs_metadata` directly.
    pub media_type: String,
    /// One of `"trending" | "popular" | "upcoming" | "now_playing" |
    /// "on_the_air" | "airing_today"`. Unknown values are coerced to
    /// `"trending"` by the relay client.
    pub category: String,
    /// ISO 639-1 code (e.g. `"en"`, `"ja"`, `"es"`).
    pub language: String,
    /// 1-based page index. The page renders 20 items per page (TMDB
    /// default).
    pub page: u32,
}

impl Default for DiscoverQuery {
    fn default() -> Self {
        Self {
            media_type: "movie".into(),
            category: "trending".into(),
            language: "en".into(),
            page: 1,
        }
    }
}

/// One row in the discover grid. Flattens the
/// [`mydia_rs_metadata::SearchResult`] fields the UI actually needs
/// so the page doesn't drag the structs crate in just for renders.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DiscoverItem {
    pub provider_id: String,
    pub title: String,
    pub year: Option<i32>,
    pub overview: Option<String>,
    pub poster_path: Option<String>,
    pub vote_average: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DiscoverPage {
    pub items: Vec<DiscoverItem>,
    pub page: u32,
    pub total_pages: u32,
}

#[post("/api/discover")]
pub async fn discover(query: DiscoverQuery) -> Result<DiscoverPage, ServerFnError> {
    server::discover(query).await
}

#[cfg(feature = "server")]
mod server {
    use super::{DiscoverItem, DiscoverPage, DiscoverQuery};
    use crate::server_fns::auth::require_session_user_id;
    use dioxus::fullstack::ServerFnError;
    use mydia_rs_metadata::structs::{MediaType, SearchResult};
    use mydia_rs_metadata::{provider::ProviderConfig, provider::TrendingOpts, relay::Relay};

    pub(super) async fn discover(query: DiscoverQuery) -> Result<DiscoverPage, ServerFnError> {
        require_session_user_id().await?;
        let media_type = parse_media_type(&query.media_type);
        let category = sanitize_category(&query.category);
        let opts = TrendingOpts {
            media_type: Some(media_type),
            language: Some(query.language.clone()),
            page: Some(query.page.max(1)),
        };
        let config = ProviderConfig::metadata_relay_default();
        let relay = Relay::new();
        let result = relay
            .fetch_curated(&config, &category, &opts)
            .await
            .map_err(|err| ServerFnError::new(format!("metadata-relay: {err}")))?;
        Ok(DiscoverPage {
            items: result.results.into_iter().map(into_item).collect(),
            page: result.page,
            total_pages: result.total_pages,
        })
    }

    fn parse_media_type(s: &str) -> MediaType {
        match s {
            "tv_show" | "tv" => MediaType::TvShow,
            // Default to Movie for movie / unknown.
            _ => MediaType::Movie,
        }
    }

    fn sanitize_category(s: &str) -> String {
        match s {
            "trending" | "popular" | "upcoming" | "now_playing" | "on_the_air" | "airing_today" => {
                s.to_owned()
            }
            _ => "trending".to_owned(),
        }
    }

    fn into_item(r: SearchResult) -> DiscoverItem {
        // TMDB returns `title` for movies, `name` for TV. Either is
        // acceptable as the headline label; pick whichever the
        // payload populated, fall back to original_title/original_name
        // before giving up with "(Untitled)".
        let title = r
            .title
            .or(r.name)
            .or(r.original_title)
            .or(r.original_name)
            .unwrap_or_else(|| "(Untitled)".to_owned());
        let year = r
            .year
            .or_else(|| year_from_date(r.release_date.as_deref()))
            .or_else(|| year_from_date(r.first_air_date.as_deref()));
        DiscoverItem {
            provider_id: r.provider_id,
            title,
            year,
            overview: r.overview,
            poster_path: r.poster_path,
            vote_average: r.vote_average,
        }
    }

    fn year_from_date(s: Option<&str>) -> Option<i32> {
        // TMDB ships `release_date` as `YYYY-MM-DD`; extract the year
        // by taking the first four chars. Falls back to None on
        // anything shorter (partial dates `"2024"` are already handled
        // by SearchResult.year on the parser side).
        s.and_then(|raw| raw.get(..4)?.parse::<i32>().ok())
    }
}
