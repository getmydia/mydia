//! Port of `Mydia.Media.MediaItem` (`lib/mydia/media/media_item.ex`).
//!
//! Phoenix table: `media_items`. Holds the parent record for both
//! movies and TV shows; `type` discriminates. `metadata` is the
//! `Mydia.Media.MetadataType` custom Ecto type holding a JSON payload —
//! ported as [`JsonMap<serde_json::Value>`] until the typed
//! `MediaMetadata` struct lands in a later unit.

use mydia_rs_db::types::{DateTimeSecs, JsonMap, UuidText};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, sqlx::FromRow, Serialize, Deserialize)]
pub struct MediaItem {
    pub id: UuidText,
    pub r#type: Option<String>,
    pub title: Option<String>,
    pub original_title: Option<String>,
    pub year: Option<i32>,
    pub tmdb_id: Option<i64>,
    pub tvdb_id: Option<i64>,
    pub imdb_id: Option<String>,
    pub metadata: Option<JsonMap<serde_json::Value>>,
    pub monitored: bool,
    pub monitoring_preset: String,
    pub category: Option<String>,
    pub category_override: bool,
    pub seasons_refreshed_at: Option<DateTimeSecs>,
    pub quality_profile_id: Option<UuidText>,
    pub inserted_at: DateTimeSecs,
    pub updated_at: DateTimeSecs,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaKind {
    Movie,
    TvShow,
}

impl MediaKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Movie => "movie",
            Self::TvShow => "tv_show",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "movie" => Some(Self::Movie),
            "tv_show" => Some(Self::TvShow),
            _ => None,
        }
    }
}

/// Typed mirror of the `monitoring_preset` Ecto enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MonitoringPreset {
    All,
    Future,
    Missing,
    Existing,
    FirstSeason,
    LatestSeason,
    None,
}

impl MonitoringPreset {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::Future => "future",
            Self::Missing => "missing",
            Self::Existing => "existing",
            Self::FirstSeason => "first_season",
            Self::LatestSeason => "latest_season",
            Self::None => "none",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "all" => Some(Self::All),
            "future" => Some(Self::Future),
            "missing" => Some(Self::Missing),
            "existing" => Some(Self::Existing),
            "first_season" => Some(Self::FirstSeason),
            "latest_season" => Some(Self::LatestSeason),
            "none" => Some(Self::None),
            _ => None,
        }
    }
}

impl MediaItem {
    pub fn kind(&self) -> Option<MediaKind> {
        self.r#type.as_deref().and_then(MediaKind::parse)
    }

    pub fn monitoring_preset(&self) -> Option<MonitoringPreset> {
        MonitoringPreset::parse(&self.monitoring_preset)
    }
}
