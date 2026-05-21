//! TV show type — port of `lib/mydia_web/schema/media_types.ex:96-188`.
//!
//! Adds the derived `status`, `seasons`, `season_count`,
//! `episode_count`, `next_episode` fields on top of the same metadata
//! shape Movie uses. `next_episode` is user-scoped and follows the
//! anonymous-fallback convention until the auth middleware lands.

use std::collections::BTreeMap;

use async_graphql::{ComplexObject, Context, SimpleObject, ID};
use chrono::{DateTime, Utc};
use serde_json::Value;

use crate::context::GraphqlAppState;
use crate::metadata;
use crate::node_id::{NodeId, NodeRef};
use crate::queries::browse::MediaCategory;
use crate::repos::media as media_repo;
use crate::types::{Artwork, Episode, Season};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "TvShow", complex)]
pub struct TvShow {
    pub id: ID,
    pub title: String,
    pub original_title: Option<String>,
    pub year: Option<i32>,
    pub tmdb_id: Option<i64>,
    pub tvdb_id: Option<i64>,
    pub imdb_id: Option<String>,
    pub monitored: bool,
    pub added_at: DateTime<Utc>,

    #[graphql(skip)]
    pub plain_id: String,
    #[graphql(skip)]
    pub raw_metadata: Option<Value>,
    #[graphql(skip)]
    pub raw_category: Option<String>,
}

#[ComplexObject]
impl TvShow {
    async fn overview(&self) -> Option<String> {
        metadata::get_str(self.raw_metadata.as_ref(), "overview")
            .map(std::borrow::ToOwned::to_owned)
    }

    /// `metadata.status` — e.g. "Continuing", "Ended".
    async fn status(&self) -> Option<String> {
        metadata::get_str(self.raw_metadata.as_ref(), "status").map(std::borrow::ToOwned::to_owned)
    }

    async fn genres(&self) -> Vec<String> {
        metadata::get_string_array(self.raw_metadata.as_ref(), "genres")
    }

    async fn content_rating(&self) -> Option<String> {
        None
    }

    async fn rating(&self) -> Option<f64> {
        metadata::get_f64(self.raw_metadata.as_ref(), "vote_average")
    }

    async fn artwork(&self) -> Option<Artwork> {
        let poster =
            metadata::poster_url(metadata::get_str(self.raw_metadata.as_ref(), "poster_path"));
        let backdrop = metadata::backdrop_url(metadata::get_str(
            self.raw_metadata.as_ref(),
            "backdrop_path",
        ));
        if poster.is_none() && backdrop.is_none() {
            return None;
        }
        Some(Artwork {
            poster_url: poster,
            backdrop_url: backdrop,
            thumbnail_url: None,
        })
    }

    async fn category(&self) -> Option<MediaCategory> {
        match self.raw_category.as_deref() {
            Some("anime") => Some(MediaCategory::Anime),
            Some("standard") => Some(MediaCategory::Standard),
            Some("documentary") => Some(MediaCategory::Documentary),
            Some("stand_up") => Some(MediaCategory::StandUp),
            Some("reality") => Some(MediaCategory::Reality),
            Some("adult") => Some(MediaCategory::Adult),
            _ => None,
        }
    }

    /// List seasons aggregated from the episodes table.
    async fn seasons(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<Season>> {
        let state = ctx.data::<GraphqlAppState>()?;
        let episodes = media_repo::list_episodes(&state.db, &self.plain_id).await?;
        Ok(group_into_seasons(&self.plain_id, &episodes))
    }

    /// Total number of seasons.
    async fn season_count(&self, ctx: &Context<'_>) -> async_graphql::Result<i32> {
        let state = ctx.data::<GraphqlAppState>()?;
        let episodes = media_repo::list_episodes(&state.db, &self.plain_id).await?;
        let unique: std::collections::HashSet<i32> =
            episodes.iter().filter_map(|e| e.season_number).collect();
        Ok(unique.len() as i32)
    }

    /// Total number of episodes across all seasons.
    async fn episode_count(&self, ctx: &Context<'_>) -> async_graphql::Result<i32> {
        let state = ctx.data::<GraphqlAppState>()?;
        let episodes = media_repo::list_episodes(&state.db, &self.plain_id).await?;
        Ok(episodes.len() as i32)
    }

    /// Next episode to watch for the current user. Anonymous
    /// fallback returns `None`.
    async fn next_episode(&self, _ctx: &Context<'_>) -> Option<Episode> {
        None
    }

    async fn is_favorite(&self, _ctx: &Context<'_>) -> bool {
        false
    }
}

impl TvShow {
    pub fn from_row(row: &mydia_rs_models::MediaItem) -> Option<Self> {
        if row.r#type.as_deref() != Some("tv_show") {
            return None;
        }
        Some(Self {
            id: NodeId::TvShow(NodeRef::Str(row.id.0.to_string()))
                .encode()
                .into(),
            title: row.title.clone().unwrap_or_default(),
            original_title: row.original_title.clone(),
            year: row.year,
            tmdb_id: row.tmdb_id,
            tvdb_id: row.tvdb_id,
            imdb_id: row.imdb_id.clone(),
            monitored: row.monitored,
            added_at: row.inserted_at.0,
            plain_id: row.id.0.to_string(),
            raw_metadata: row.metadata.as_ref().map(|m| m.0.clone()),
            raw_category: row.category.clone(),
        })
    }
}

/// Group an episode list into `Season` aggregates keyed by season
/// number. Returns seasons sorted ascending. Used by the `seasons`
/// resolver above.
fn group_into_seasons(show_id: &str, episodes: &[mydia_rs_models::Episode]) -> Vec<Season> {
    let mut buckets: BTreeMap<i32, Vec<&mydia_rs_models::Episode>> = BTreeMap::new();
    for ep in episodes {
        if let Some(num) = ep.season_number {
            buckets.entry(num).or_default().push(ep);
        }
    }
    buckets
        .into_iter()
        .filter_map(|(season_number, eps_in_season)| {
            // has_files would require an extra query per season —
            // expensive to compute synchronously here. Phoenix's
            // `seasons` field doesn't surface has_files either; the
            // player only renders has_files in the standalone
            // `season(showId, seasonNumber)` query (U10.a). Stub
            // false here.
            let _ = eps_in_season;
            Season::build(show_id, season_number, episodes, false)
        })
        .collect()
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "TvShowEdge")]
pub struct TvShowEdge {
    pub node: TvShow,
    pub cursor: String,
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "TvShowConnection")]
pub struct TvShowConnection {
    pub edges: Vec<TvShowEdge>,
    pub page_info: super::PageInfo,
    pub total_count: i32,
}
