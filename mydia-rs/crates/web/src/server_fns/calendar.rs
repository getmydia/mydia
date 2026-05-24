//! Calendar server functions (U27 — calendar page).
//!
//! Phoenix counterpart: `MydiaWeb.CalendarLive.Index` +
//! `Mydia.Media.{list_episodes_by_air_date, list_movies_by_release_date}`.
//! The Phoenix page renders a month grid of upcoming episodes and movies;
//! the Rust port keeps the same data shape but punts the calendar-grid
//! generation to the client so the server only ships the entries plus
//! their air date.
//!
//! Scope is narrowed to the operator audience: every entry is returned
//! regardless of monitored state (the Phoenix page already passes
//! `monitored: nil`). Music, books, and adult are excluded by virtue of
//! filtering on `media_items.type IN ('movie', 'tv_show')` — those
//! domains are deprecated per the U27 brief.
//!
//! Movie release dates are stored in `media_items.metadata.release_date`
//! (a JSON column). The Phoenix code reads them out post-fetch; we do
//! the same since the data volume per month is tiny and the JSON read
//! path is portable across `SQLite` + Postgres.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// One row in the calendar grid — either an episode or a movie.
///
/// `air_date` is an ISO-8601 `YYYY-MM-DD` string (server-side computed
/// so the wasm client doesn't need `chrono`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CalendarEntry {
    pub id: String,
    /// `"episode"` or `"movie"`. Matches Phoenix's `CalendarEntry.type`.
    pub kind: String,
    pub air_date: String,
    pub title: Option<String>,
    pub season_number: Option<i64>,
    pub episode_number: Option<i64>,
    pub media_item_id: String,
    pub media_item_title: Option<String>,
    pub media_item_type: Option<String>,
    pub has_files: bool,
    pub has_downloads: bool,
}

/// Wire-payload for the calendar query — bind the visible month to the
/// query so a previous-month / next-month click can re-fetch without
/// re-deriving the date range client-side.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CalendarQuery {
    pub year: i32,
    /// 1..=12 (calendar month). Out-of-range values fall back to the
    /// current month.
    pub month: u32,
    /// `"all"` / `"movie"` / `"tv_show"`. Unknown values mean `"all"`.
    #[serde(default = "default_filter")]
    pub filter: String,
}

fn default_filter() -> String {
    "all".to_owned()
}

#[get("/api/calendar")]
pub async fn list_calendar(query: CalendarQuery) -> Result<Vec<CalendarEntry>, ServerFnError> {
    server::list(query).await
}

#[cfg(feature = "server")]
mod server {
    use super::{CalendarEntry, CalendarQuery};
    use crate::server_fns::auth::require_session_user_id;
    use crate::server_state::WebState;
    use chrono::{Datelike, Duration as ChronoDuration, NaiveDate, Utc};
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_db::DatabaseConnection;
    use mydia_rs_entities::{downloads, episodes, media_files, media_items};
    use sea_orm::entity::prelude::*;
    use sea_orm::query::QueryOrder;
    use sea_orm::sea_query::{Expr, ExprTrait, Query};
    use std::collections::HashSet;

    fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    pub(super) async fn list(query: CalendarQuery) -> Result<Vec<CalendarEntry>, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;

        let (start, end) = month_range(query.year, query.month);

        let filter = sanitize_filter(&query.filter);
        let include_episodes = matches!(filter.as_str(), "all" | "tv_show");
        let include_movies = matches!(filter.as_str(), "all" | "movie");

        let mut out: Vec<CalendarEntry> = Vec::new();
        if include_episodes {
            out.extend(list_episodes_for_range(&st.db, start, end).await?);
        }
        if include_movies {
            out.extend(list_movies_for_range(&st.db, start, end).await?);
        }

        // Stable sort by air_date so the client can group/page directly
        // off the returned vector without a second pass.
        out.sort_by(|a, b| a.air_date.cmp(&b.air_date));
        Ok(out)
    }

    fn sanitize_filter(s: &str) -> String {
        match s {
            "movie" => "movie".to_owned(),
            "tv_show" => "tv_show".to_owned(),
            _ => "all".to_owned(),
        }
    }

    fn month_range(year: i32, month: u32) -> (NaiveDate, NaiveDate) {
        // Out-of-range month? Fall back to today's month so a malformed
        // query still renders something useful rather than a 500.
        let start = NaiveDate::from_ymd_opt(year, month.clamp(1, 12), 1)
            .unwrap_or_else(|| Utc::now().date_naive().with_day(1).unwrap_or_default());
        let next = if start.month() == 12 {
            NaiveDate::from_ymd_opt(start.year() + 1, 1, 1).unwrap_or(start)
        } else {
            NaiveDate::from_ymd_opt(start.year(), start.month() + 1, 1).unwrap_or(start)
        };
        let end = next - ChronoDuration::days(1);
        (start, end)
    }

    async fn list_episodes_for_range(
        db: &DatabaseConnection,
        start: NaiveDate,
        end: NaiveDate,
    ) -> Result<Vec<CalendarEntry>, ServerFnError> {
        // The original Phoenix query JOINs episodes -> media_items and
        // computes `has_files` / `has_downloads` via correlated EXISTS
        // subqueries on `media_files.episode_id` / `downloads.episode_id`.
        // Translated to SeaORM: pull the candidate episodes, then bulk
        // load the matching media_files/downloads sets and compute the
        // boolean flags in Rust. Trades one query for three, but each is
        // a tightly scoped index lookup so the cost is comparable.
        let eps = episodes::Entity::find()
            .filter(episodes::Column::AirDate.is_not_null())
            .filter(episodes::Column::AirDate.gte(start))
            .filter(episodes::Column::AirDate.lte(end))
            .order_by_asc(episodes::Column::AirDate)
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("list episodes: {err}")))?;

        if eps.is_empty() {
            return Ok(Vec::new());
        }

        // Pull the parent media_items in one shot.
        let media_item_ids: Vec<_> = eps.iter().map(|e| e.media_item_id.clone()).collect();
        let parents = media_items::Entity::find()
            .filter(media_items::Column::Id.is_in(media_item_ids.clone()))
            .filter(media_items::Column::Type.eq("tv_show".to_owned()))
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("list media_items: {err}")))?;
        let mut parent_map = std::collections::HashMap::new();
        for parent in parents {
            parent_map.insert(parent.id.clone(), parent);
        }

        let episode_ids: Vec<_> = eps.iter().map(|e| e.id.clone()).collect();
        let files = media_files::Entity::find()
            .select_only()
            .column(media_files::Column::EpisodeId)
            .filter(media_files::Column::EpisodeId.is_in(episode_ids.clone()))
            .into_tuple::<Option<mydia_rs_db::types::UuidText>>()
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("query media_files: {err}")))?;
        let files_set: HashSet<_> = files.into_iter().flatten().collect();

        let downloads_rows = downloads::Entity::find()
            .select_only()
            .column(downloads::Column::EpisodeId)
            .filter(downloads::Column::EpisodeId.is_in(episode_ids))
            .into_tuple::<Option<mydia_rs_db::types::UuidText>>()
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("query downloads: {err}")))?;
        let downloads_set: HashSet<_> = downloads_rows.into_iter().flatten().collect();

        let mut out: Vec<CalendarEntry> = Vec::new();
        for e in eps {
            let Some(parent) = parent_map.get(&e.media_item_id) else {
                continue;
            };
            let Some(ad) = e.air_date else { continue };
            out.push(CalendarEntry {
                id: e.id.to_string(),
                kind: "episode".to_owned(),
                air_date: ad.format("%Y-%m-%d").to_string(),
                title: e.title.clone(),
                season_number: Some(i64::from(e.season_number)),
                episode_number: Some(i64::from(e.episode_number)),
                media_item_id: parent.id.to_string(),
                media_item_title: Some(parent.title.clone()),
                media_item_type: Some("tv_show".to_owned()),
                has_files: files_set.contains(&e.id),
                has_downloads: downloads_set.contains(&e.id),
            });
        }
        // Stable sort by (air_date, title) to mirror Phoenix.
        out.sort_by(|a, b| {
            a.air_date
                .cmp(&b.air_date)
                .then_with(|| a.media_item_title.cmp(&b.media_item_title))
        });
        Ok(out)
    }

    async fn list_movies_for_range(
        db: &DatabaseConnection,
        start: NaiveDate,
        end: NaiveDate,
    ) -> Result<Vec<CalendarEntry>, ServerFnError> {
        // Pull every movie + metadata + flags. The Phoenix path does
        // the same in-memory release_date filter; we mirror it.
        let movies = media_items::Entity::find()
            .filter(media_items::Column::Type.eq("movie".to_owned()))
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("list movies: {err}")))?;

        if movies.is_empty() {
            return Ok(Vec::new());
        }

        let movie_ids: Vec<_> = movies.iter().map(|m| m.id.clone()).collect();
        let files = media_files::Entity::find()
            .select_only()
            .column(media_files::Column::MediaItemId)
            .filter(media_files::Column::MediaItemId.is_in(movie_ids.clone()))
            .filter(media_files::Column::EpisodeId.is_null())
            .into_tuple::<Option<mydia_rs_db::types::UuidText>>()
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("query media_files: {err}")))?;
        let files_set: HashSet<_> = files.into_iter().flatten().collect();

        let dl_rows = downloads::Entity::find()
            .select_only()
            .column(downloads::Column::MediaItemId)
            .filter(downloads::Column::MediaItemId.is_in(movie_ids))
            .into_tuple::<Option<mydia_rs_db::types::UuidText>>()
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("query downloads: {err}")))?;
        let downloads_set: HashSet<_> = dl_rows.into_iter().flatten().collect();

        let _ = Query::select(); // keep the import live in case future filters need it
        let mut entries: Vec<CalendarEntry> = Vec::new();
        for m in movies {
            let Some(release_date) = extract_release_date(m.metadata.as_deref()) else {
                continue;
            };
            if release_date < start || release_date > end {
                continue;
            }
            let id_str = m.id.to_string();
            entries.push(CalendarEntry {
                id: id_str.clone(),
                kind: "movie".to_owned(),
                air_date: release_date.format("%Y-%m-%d").to_string(),
                title: Some(m.title.clone()),
                season_number: None,
                episode_number: None,
                media_item_id: id_str,
                media_item_title: Some(m.title),
                media_item_type: Some("movie".to_owned()),
                has_files: files_set.contains(&m.id),
                has_downloads: downloads_set.contains(&m.id),
            });
        }
        Ok(entries)
    }

    /// Pull `metadata.release_date` out of the JSON column. Returns
    /// `None` if the column is missing, malformed, or the date is
    /// unparseable — every failure mode collapses to "skip this movie"
    /// rather than erroring the whole query.
    fn extract_release_date(metadata_json: Option<&str>) -> Option<NaiveDate> {
        let raw = metadata_json?;
        let value: serde_json::Value = serde_json::from_str(raw).ok()?;
        let release_date = value.get("release_date")?.as_str()?;
        NaiveDate::parse_from_str(release_date, "%Y-%m-%d").ok()
    }
}
