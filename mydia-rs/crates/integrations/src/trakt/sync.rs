//! Two-way Trakt sync helpers.
//!
//! Port of `lib/mydia/integrations/trakt/sync.ex`. The Phoenix module
//! mixes "fetch from Trakt", "match to local DB", "write progress", and
//! "build push payload" in one place. The Rust port splits the
//! work — this module holds the payload builders and the matching
//! policy. The U17 `TraktSync` worker owns the DB writes and consumes
//! these helpers.
//!
//! Why split: the matching policy (Trakt IDs map → local `MediaItem`
//! via tmdb/imdb/tvdb) is testable in isolation, while the DB-side is
//! integration-tested with a live pool.

use chrono::{DateTime, Utc};
use serde::Deserialize;

use crate::trakt::client::{build_ids, TraktMoviePayload, TraktShowPayload};

/// One Trakt history entry parsed from the `/sync/history/movies`
/// endpoint. Optional fields mirror the Trakt API surface; we only
/// take what we need.
#[derive(Debug, Clone, Deserialize)]
pub struct TraktHistoryMovie {
    #[serde(default)]
    pub watched_at: Option<String>,
    pub movie: TraktMovieRef,
}

/// One Trakt history entry from `/sync/history/episodes`.
#[derive(Debug, Clone, Deserialize)]
pub struct TraktHistoryEpisode {
    #[serde(default)]
    pub watched_at: Option<String>,
    pub show: TraktShowRef,
    pub episode: TraktEpisodeRef,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TraktMovieRef {
    pub title: Option<String>,
    pub year: Option<i32>,
    pub ids: TraktIds,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TraktShowRef {
    pub title: Option<String>,
    pub year: Option<i32>,
    pub ids: TraktIds,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TraktEpisodeRef {
    pub season: Option<i32>,
    pub number: Option<i32>,
}

/// External-ID block Trakt attaches to every movie / show response.
/// All fields are `Option<>` because Trakt returns whichever providers
/// it has matched.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct TraktIds {
    #[serde(default)]
    pub imdb: Option<String>,
    #[serde(default, deserialize_with = "deserialize_id_as_string")]
    pub tmdb: Option<String>,
    #[serde(default, deserialize_with = "deserialize_id_as_string")]
    pub tvdb: Option<String>,
    #[serde(default)]
    pub trakt: Option<serde_json::Value>,
    #[serde(default)]
    pub slug: Option<String>,
}

/// Local item shape the matcher needs. Worker code constructs this
/// from a sqlx-fetched `MediaItem` before calling the helpers below —
/// keeps the matcher decoupled from the schema.
#[derive(Debug, Clone)]
pub struct LocalMediaItem {
    pub id: String,
    pub title: String,
    pub year: Option<i32>,
    pub imdb_id: Option<String>,
    pub tmdb_id: Option<String>,
    pub tvdb_id: Option<String>,
}

/// Format the `last_synced_at` watermark for `?start_at=`.
#[must_use]
pub fn format_start_at(last_synced_at: Option<DateTime<Utc>>) -> Option<String> {
    last_synced_at.map(|dt| dt.to_rfc3339())
}

/// Build a Trakt movie payload for history-push or collection-push.
/// Returns `None` when the item has no external IDs Trakt would
/// recognize.
#[must_use]
pub fn build_movie_payload(
    item: &LocalMediaItem,
    watched_at: Option<DateTime<Utc>>,
) -> Option<TraktMoviePayload> {
    let ids = build_ids(
        item.imdb_id.as_deref(),
        item.tmdb_id.as_deref(),
        item.tvdb_id.as_deref(),
    )?;
    Some(TraktMoviePayload {
        ids,
        title: item.title.clone(),
        year: item.year,
        watched_at: watched_at.map(|dt| dt.to_rfc3339()),
    })
}

/// Build a Trakt show payload for collection-push.
#[must_use]
pub fn build_show_payload(item: &LocalMediaItem) -> Option<TraktShowPayload> {
    let ids = build_ids(
        item.imdb_id.as_deref(),
        item.tmdb_id.as_deref(),
        item.tvdb_id.as_deref(),
    )?;
    Some(TraktShowPayload {
        ids,
        title: item.title.clone(),
        year: item.year,
    })
}

/// Build the `seasons`/`episodes` push payload for one watched episode.
#[must_use]
pub fn build_episode_history_payload(
    show: &LocalMediaItem,
    season_number: i32,
    episode_number: i32,
    watched_at: Option<DateTime<Utc>>,
) -> Option<serde_json::Value> {
    let ids = build_ids(
        show.imdb_id.as_deref(),
        show.tmdb_id.as_deref(),
        show.tvdb_id.as_deref(),
    )?;
    let watched_at_str = watched_at.map(|dt| dt.to_rfc3339());

    Some(serde_json::json!({
        "ids": ids,
        "title": show.title,
        "year": show.year,
        "seasons": [{
            "number": season_number,
            "episodes": [{
                "number": episode_number,
                "watched_at": watched_at_str
            }]
        }]
    }))
}

/// Trakt IDs come in as `i64` or `String`; normalize either to a
/// String so the matcher can compare against local DB columns
/// (Phoenix stores all external IDs as text).
fn deserialize_id_as_string<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de::Error as _;
    let v = serde_json::Value::deserialize(deserializer)?;
    match v {
        serde_json::Value::Null => Ok(None),
        serde_json::Value::String(s) => Ok(Some(s)),
        serde_json::Value::Number(n) => Ok(Some(n.to_string())),
        other => Err(D::Error::custom(format!(
            "expected string or number, got {other}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn local_item_with_ids() -> LocalMediaItem {
        LocalMediaItem {
            id: "abc".into(),
            title: "Inception".into(),
            year: Some(2010),
            imdb_id: Some("tt1375666".into()),
            tmdb_id: Some("27205".into()),
            tvdb_id: None,
        }
    }

    fn local_item_without_ids() -> LocalMediaItem {
        LocalMediaItem {
            id: "abc".into(),
            title: "Unknown".into(),
            year: None,
            imdb_id: None,
            tmdb_id: None,
            tvdb_id: None,
        }
    }

    #[test]
    fn movie_payload_includes_external_ids() {
        let p = build_movie_payload(&local_item_with_ids(), None).unwrap();
        assert_eq!(p.title, "Inception");
        assert_eq!(p.year, Some(2010));
        assert_eq!(p.ids.get("imdb").unwrap(), "tt1375666");
        assert_eq!(p.ids.get("tmdb").unwrap(), "27205");
    }

    #[test]
    fn item_without_ids_yields_no_payload() {
        assert!(build_movie_payload(&local_item_without_ids(), None).is_none());
        assert!(build_show_payload(&local_item_without_ids()).is_none());
    }

    #[test]
    fn episode_payload_wraps_in_seasons() {
        let payload = build_episode_history_payload(&local_item_with_ids(), 1, 3, None).unwrap();
        let seasons = payload.get("seasons").unwrap().as_array().unwrap();
        assert_eq!(seasons.len(), 1);
        assert_eq!(seasons[0].get("number").unwrap(), 1);
        let episodes = seasons[0].get("episodes").unwrap().as_array().unwrap();
        assert_eq!(episodes[0].get("number").unwrap(), 3);
    }

    #[test]
    fn format_start_at_is_rfc3339() {
        let dt = Utc::now();
        let formatted = format_start_at(Some(dt)).unwrap();
        assert!(formatted.contains('T'));
        assert!(formatted.ends_with('Z') || formatted.contains("+00:00"));
    }

    #[test]
    fn trakt_ids_accepts_numeric_or_string() {
        let json = serde_json::json!({ "imdb": "tt9", "tmdb": 42, "tvdb": "abc" });
        let ids: TraktIds = serde_json::from_value(json).unwrap();
        assert_eq!(ids.imdb.as_deref(), Some("tt9"));
        assert_eq!(ids.tmdb.as_deref(), Some("42"));
        assert_eq!(ids.tvdb.as_deref(), Some("abc"));
    }
}
