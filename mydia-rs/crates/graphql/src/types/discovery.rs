//! Discovery item types — port of `lib/mydia_web/schema/query_types.ex`
//! object definitions for the home-screen rails.
//!
//! The Phoenix discovery resolver builds these shapes inline in the
//! resolver. The mirror types here let the Rust resolver return
//! strongly-typed values without round-tripping through `serde_json`.

use async_graphql::{Enum, SimpleObject, ID};
use chrono::{DateTime, Utc};

use crate::types::{Artwork, Episode, Progress, TvShow};

/// Discriminator for items that can appear in mixed rails
/// (continueWatching, recentlyAdded, favorites). Mirrors the
/// Absinthe `:media_type` enum.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Enum)]
#[graphql(name = "MediaType")]
pub enum MediaType {
    Movie,
    TvShow,
    Episode,
}

impl MediaType {
    pub fn from_db_str(value: &str) -> Option<Self> {
        match value {
            "movie" => Some(Self::Movie),
            "tv_show" => Some(Self::TvShow),
            "episode" => Some(Self::Episode),
            _ => None,
        }
    }
}

/// Continue-watching rail item.
#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "ContinueWatchingItem")]
pub struct ContinueWatchingItem {
    pub id: ID,
    #[graphql(name = "type")]
    pub type_: MediaType,
    pub title: String,
    pub artwork: Option<Artwork>,
    pub progress: Progress,
    /// Set on episode items only.
    pub show_id: Option<ID>,
    pub show_title: Option<String>,
    pub season_number: Option<i32>,
    pub episode_number: Option<i32>,
}

/// Recently-added rail item. Also returned by the favorites and
/// unwatched queries.
#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "RecentlyAddedItem")]
pub struct RecentlyAddedItem {
    pub id: ID,
    #[graphql(name = "type")]
    pub type_: MediaType,
    pub title: String,
    pub year: Option<i32>,
    pub artwork: Option<Artwork>,
    pub added_at: DateTime<Utc>,
}

/// Up-next rail item — next episode to watch per show. The
/// `progress_state` discriminates between "continue" (mid-episode),
/// "next" (next episode after a fully-watched prior one), and
/// "start" (no progress yet, first unwatched episode).
#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "UpNextItem")]
pub struct UpNextItem {
    pub episode: Episode,
    pub show: TvShow,
    /// One of: `"continue"`, `"next"`, `"start"`.
    pub progress_state: String,
}

/// Discover item — a TMDB result surfaced on the Discover page.
/// These are media items NOT yet in the user's library (or may be,
/// indicated by `in_library`).
#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "DiscoverItem")]
pub struct DiscoverItem {
    pub id: ID,
    pub tmdb_id: i32,
    #[graphql(name = "type")]
    pub type_: MediaType,
    pub title: String,
    pub year: Option<i32>,
    pub poster_url: Option<String>,
    pub vote_average: Option<f64>,
    pub in_library: bool,
}

/// Single page of discover/curated results.
#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "DiscoverPage")]
pub struct DiscoverPage {
    pub results: Vec<DiscoverItem>,
    pub page: i32,
    pub total_pages: i32,
}
