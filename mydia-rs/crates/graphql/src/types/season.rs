//! Season — virtual type, port of `lib/mydia_web/schema/media_types.ex:190-233`.
//!
//! There is no `seasons` DB table; Phoenix builds Season records on
//! the fly from the episodes belonging to a `media_item`. The Rust
//! port mirrors that shape: `Season::build_from_episodes` walks an
//! episode list and computes the counts.

use async_graphql::{SimpleObject, ID};
use chrono::NaiveDate;

use crate::node_id::{NodeId, NodeRef};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "Season")]
pub struct Season {
    /// Encoded `season:<show_id>:<season_number>` form.
    pub id: ID,
    pub season_number: i32,
    pub episode_count: i32,
    pub aired_episode_count: Option<i32>,
    pub has_files: bool,
    /// Plain UUID of the parent show. Kept on the type so the U10.c
    /// Node interface resolvers can navigate to the parent without
    /// re-decoding the global ID.
    #[graphql(skip)]
    pub show_id: String,
}

impl Season {
    /// Build a Season for `season_number` from the slice of all
    /// episodes belonging to `show_id`. Returns `None` when no
    /// episodes match the season number (mirrors Phoenix's
    /// `get_season` "Season not found" branch).
    pub fn build(
        show_id: &str,
        season_number: i32,
        episodes: &[mydia_rs_models::Episode],
        has_files: bool,
    ) -> Option<Self> {
        let season_episodes: Vec<&mydia_rs_models::Episode> = episodes
            .iter()
            .filter(|e| e.season_number == Some(season_number))
            .collect();
        if season_episodes.is_empty() {
            return None;
        }

        let today = chrono::Utc::now().date_naive();
        let aired_count: i32 = season_episodes
            .iter()
            .filter(|e| matches!(e.air_date, Some(d) if d <= today))
            .count() as i32;

        Some(Self {
            id: NodeId::Season {
                show_id: NodeRef::Str(show_id.to_owned()),
                season_number,
            }
            .encode()
            .into(),
            season_number,
            episode_count: season_episodes.len() as i32,
            aired_episode_count: Some(aired_count),
            has_files,
            show_id: show_id.to_owned(),
        })
    }

    /// Build a season ignoring air-date filtering. Used in the
    /// `seasons` field resolver on `TvShow` (U10.c) where the resolver
    /// already paginates by season.
    #[allow(dead_code)]
    pub fn build_unchecked(
        show_id: &str,
        season_number: i32,
        episodes_in_season: i32,
        has_files: bool,
        air_dates: &[Option<NaiveDate>],
    ) -> Self {
        let today = chrono::Utc::now().date_naive();
        let aired_count: i32 = air_dates
            .iter()
            .filter(|d| matches!(d, Some(d) if *d <= today))
            .count() as i32;
        Self {
            id: NodeId::Season {
                show_id: NodeRef::Str(show_id.to_owned()),
                season_number,
            }
            .encode()
            .into(),
            season_number,
            episode_count: episodes_in_season,
            aired_episode_count: Some(aired_count),
            has_files,
            show_id: show_id.to_owned(),
        }
    }
}
