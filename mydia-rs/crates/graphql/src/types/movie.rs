//! Movie type — port of `lib/mydia_web/schema/media_types.ex:11-93`.
//!
//! The Phoenix `:movie` object exposes ~25 fields, most of which are
//! derived from the `metadata` JSON blob via `MetadataAccess`. U10.a
//! ships the direct-column shape (id, title, year, monitored, etc.);
//! the derived fields (overview, runtime, genres, rating, artwork,
//! files, progress, is_favorite, category override, content rating)
//! land in U10.c when the `Mydia.Metadata.Access` port lands.
//!
//! `Movie` implements the Node interface in U10.c (the
//! `parent`/`children`/`ancestors`/`is_playable` resolvers attach
//! through `#[ComplexObject]`).

use async_graphql::{SimpleObject, ID};
use chrono::{DateTime, Utc};

use crate::node_id::{NodeId, NodeRef};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "Movie")]
pub struct Movie {
    /// Encoded `movie:<uuid>` form. Round-trips through
    /// [`crate::node_id::NodeId::decode`].
    pub id: ID,
    pub title: String,
    pub original_title: Option<String>,
    pub year: Option<i32>,
    pub tmdb_id: Option<i64>,
    pub tvdb_id: Option<i64>,
    pub imdb_id: Option<String>,
    pub monitored: bool,
    pub added_at: DateTime<Utc>,
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
