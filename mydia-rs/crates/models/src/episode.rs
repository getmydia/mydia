//! Port of `Mydia.Media.Episode` (`lib/mydia/media/episode.ex`).
//!
//! Phoenix table: `episodes`. `metadata` is the
//! `Mydia.Media.EpisodeDataType` custom Ecto JSON-text type, ported as
//! [`JsonMap<serde_json::Value>`] until the typed struct lands.

use chrono::NaiveDate;
use mydia_rs_db::types::{DateTimeSecs, JsonMap, UuidText};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Episode {
    pub id: UuidText,
    pub media_item_id: UuidText,
    pub season_number: Option<i32>,
    pub episode_number: Option<i32>,
    pub title: Option<String>,
    pub air_date: Option<NaiveDate>,
    pub metadata: Option<JsonMap<serde_json::Value>>,
    pub monitored: bool,
    pub inserted_at: DateTimeSecs,
    pub updated_at: DateTimeSecs,
}
