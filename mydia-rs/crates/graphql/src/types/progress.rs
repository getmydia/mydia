//! Playback progress — port of `lib/mydia_web/schema/common_types.ex:53-60`.

use async_graphql::SimpleObject;
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "Progress")]
pub struct Progress {
    pub position_seconds: i32,
    pub duration_seconds: Option<i32>,
    pub percentage: Option<f64>,
    pub watched: bool,
    pub last_watched_at: Option<DateTime<Utc>>,
}
