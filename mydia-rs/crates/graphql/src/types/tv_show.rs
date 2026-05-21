//! TV show type — port of `lib/mydia_web/schema/media_types.ex:96-188`.
//!
//! Same surface as [`crate::types::Movie`] with the addition of
//! `seasons`, `season_count`, `episode_count`, `next_episode`,
//! `status` — all derived. U10.a ships the direct-column shape;
//! the derived fields and the Node interface land in U10.c.

use async_graphql::{SimpleObject, ID};
use chrono::{DateTime, Utc};

use crate::node_id::{NodeId, NodeRef};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "TvShow")]
pub struct TvShow {
    /// Encoded `show:<uuid>` form.
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
        })
    }
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
