//! Movie type — port of `lib/mydia_web/schema/media_types.ex:11-93`.
//!
//! The Phoenix `:movie` object exposes ~25 fields split between
//! direct columns (`title`, `year`, ...) and resolver-computed
//! fields that read from the `metadata` JSON blob or run extra DB
//! queries (`overview`, `runtime`, `genres`, `files`, `progress`,
//! `artwork`, `is_favorite`, `category`). U10.c attaches the
//! computed fields via `#[ComplexObject]`.

use async_graphql::{ComplexObject, Context, SimpleObject, ID};
use chrono::{DateTime, Utc};
use serde_json::Value;

use crate::context::GraphqlAppState;
use crate::metadata;
use crate::node_id::{NodeId, NodeRef};
use crate::queries::browse::MediaCategory;
use crate::repos::media as media_repo;
use crate::types::{Artwork, MediaFile, Progress};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "Movie", complex)]
pub struct Movie {
    /// Encoded `movie:<uuid>` form.
    pub id: ID,
    pub title: String,
    pub original_title: Option<String>,
    pub year: Option<i32>,
    pub tmdb_id: Option<i64>,
    pub tvdb_id: Option<i64>,
    pub imdb_id: Option<String>,
    pub monitored: bool,
    pub added_at: DateTime<Utc>,

    /// Plain UUID of the underlying row — used by the ComplexObject
    /// resolvers to run DB queries (e.g. for `files`).
    #[graphql(skip)]
    pub plain_id: String,

    /// Raw metadata JSON blob. The ComplexObject resolvers pull
    /// overview, runtime, genres, rating, artwork paths out of this.
    #[graphql(skip)]
    pub raw_metadata: Option<Value>,

    /// `media_items.category` column. The ComplexObject `category`
    /// resolver maps it to the [`MediaCategory`] enum.
    #[graphql(skip)]
    pub raw_category: Option<String>,
}

#[ComplexObject]
impl Movie {
    /// `metadata.overview`
    async fn overview(&self) -> Option<String> {
        metadata::get_str(self.raw_metadata.as_ref(), "overview").map(|s| s.to_owned())
    }

    /// `metadata.runtime`
    async fn runtime(&self) -> Option<i32> {
        metadata::get_i64(self.raw_metadata.as_ref(), "runtime").map(|n| n as i32)
    }

    /// `metadata.genres`
    async fn genres(&self) -> Vec<String> {
        metadata::get_string_array(self.raw_metadata.as_ref(), "genres")
    }

    /// Content rating — Phoenix hardcodes `nil` (TODO note in
    /// resolver). Mirrored.
    async fn content_rating(&self) -> Option<String> {
        None
    }

    /// `metadata.vote_average`
    async fn rating(&self) -> Option<f64> {
        metadata::get_f64(self.raw_metadata.as_ref(), "vote_average")
    }

    /// Build poster / backdrop URLs from metadata paths. Returns
    /// `None` when neither path is present.
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

    /// Category enum (anime, standard, etc.).
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

    /// Available video files for the movie.
    async fn files(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<MediaFile>> {
        let state = ctx.data::<GraphqlAppState>()?;
        let rows = media_repo::list_media_files_for_movie(&state.db, &self.plain_id).await?;
        Ok(rows.iter().map(MediaFile::from_row).collect())
    }

    /// User playback progress on this movie. Returns `None` for
    /// anonymous requests; the authenticated path lights up
    /// alongside the U6 auth middleware follow-up.
    async fn progress(&self, _ctx: &Context<'_>) -> Option<Progress> {
        None
    }

    /// Whether this movie is in the user's favorites collection.
    /// Returns `false` for anonymous requests; the authenticated
    /// path lights up with the Collections context port (U14).
    async fn is_favorite(&self, _ctx: &Context<'_>) -> bool {
        false
    }
}

impl Movie {
    /// Build a `Movie` GraphQL view from the underlying DB row.
    /// Returns `None` if the row's `type` column is not `"movie"`
    /// (mirrors Phoenix's `get_movie` error branch).
    pub fn from_row(row: &mydia_rs_models::MediaItem) -> Option<Self> {
        if row.r#type.as_deref() != Some("movie") {
            return None;
        }
        Some(Self {
            id: NodeId::Movie(NodeRef::Str(row.id.0.to_string()))
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

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "MovieEdge")]
pub struct MovieEdge {
    pub node: Movie,
    pub cursor: String,
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "MovieConnection")]
pub struct MovieConnection {
    pub edges: Vec<MovieEdge>,
    pub page_info: super::PageInfo,
    pub total_count: i32,
}
