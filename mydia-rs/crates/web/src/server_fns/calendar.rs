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
    use mydia_rs_db::Db;

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

    type EpisodeRow = (
        String,
        chrono::NaiveDate,
        Option<String>,
        Option<i64>,
        Option<i64>,
        String,
        Option<String>,
        i64,
        i64,
    );

    async fn list_episodes_for_range(
        db: &Db,
        start: NaiveDate,
        end: NaiveDate,
    ) -> Result<Vec<CalendarEntry>, ServerFnError> {
        let rows: Vec<EpisodeRow> = match db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT e.id, e.air_date, e.title, e.season_number, e.episode_number, \
                        m.id, m.title, \
                        CASE WHEN EXISTS(SELECT 1 FROM media_files WHERE episode_id = e.id) \
                             THEN 1 ELSE 0 END, \
                        CASE WHEN EXISTS(SELECT 1 FROM downloads WHERE episode_id = e.id) \
                             THEN 1 ELSE 0 END \
                 FROM episodes e \
                 INNER JOIN media_items m ON e.media_item_id = m.id \
                 WHERE e.air_date IS NOT NULL \
                   AND e.air_date >= ? AND e.air_date <= ? \
                   AND m.type = 'tv_show' \
                 ORDER BY e.air_date ASC, m.title ASC",
            )
            .bind(start)
            .bind(end)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("list episodes: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT e.id, e.air_date, e.title, e.season_number, e.episode_number, \
                        m.id, m.title, \
                        CASE WHEN EXISTS(SELECT 1 FROM media_files WHERE episode_id = e.id) \
                             THEN 1 ELSE 0 END, \
                        CASE WHEN EXISTS(SELECT 1 FROM downloads WHERE episode_id = e.id) \
                             THEN 1 ELSE 0 END \
                 FROM episodes e \
                 INNER JOIN media_items m ON e.media_item_id = m.id \
                 WHERE e.air_date IS NOT NULL \
                   AND e.air_date >= $1 AND e.air_date <= $2 \
                   AND m.type = 'tv_show' \
                 ORDER BY e.air_date ASC, m.title ASC",
            )
            .bind(start)
            .bind(end)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("list episodes: {err}")))?,
        };

        Ok(rows
            .into_iter()
            .map(
                |(id, ad, title, s, e, mid, mtitle, has_files, has_downloads)| CalendarEntry {
                    id,
                    kind: "episode".to_owned(),
                    air_date: ad.format("%Y-%m-%d").to_string(),
                    title,
                    season_number: s,
                    episode_number: e,
                    media_item_id: mid,
                    media_item_title: mtitle,
                    media_item_type: Some("tv_show".to_owned()),
                    has_files: has_files != 0,
                    has_downloads: has_downloads != 0,
                },
            )
            .collect())
    }

    type MovieRow = (String, Option<String>, Option<String>, i64, i64);

    async fn list_movies_for_range(
        db: &Db,
        start: NaiveDate,
        end: NaiveDate,
    ) -> Result<Vec<CalendarEntry>, ServerFnError> {
        // Movies store `release_date` in the metadata JSON column. We
        // pull every movie's `(id, title, metadata)` and filter the
        // release_date in Rust — the row count is small enough not to
        // matter (one library has O(thousands) of movies, and most
        // libraries have far fewer). A future optimization could push
        // this into a generated column or sqlx JSON1 filter, but the
        // simple approach mirrors the Phoenix `Repo.all + Enum.filter`
        // path 1:1.
        let rows: Vec<MovieRow> = match db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT m.id, m.title, m.metadata, \
                        CASE WHEN EXISTS(SELECT 1 FROM media_files WHERE media_item_id = m.id) \
                             THEN 1 ELSE 0 END, \
                        CASE WHEN EXISTS(SELECT 1 FROM downloads WHERE media_item_id = m.id) \
                             THEN 1 ELSE 0 END \
                 FROM media_items m \
                 WHERE m.type = 'movie'",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("list movies: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT m.id, m.title, m.metadata::text, \
                        CASE WHEN EXISTS(SELECT 1 FROM media_files WHERE media_item_id = m.id) \
                             THEN 1 ELSE 0 END, \
                        CASE WHEN EXISTS(SELECT 1 FROM downloads WHERE media_item_id = m.id) \
                             THEN 1 ELSE 0 END \
                 FROM media_items m \
                 WHERE m.type = 'movie'",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("list movies: {err}")))?,
        };

        let mut entries: Vec<CalendarEntry> = Vec::new();
        for (id, title, metadata_json, has_files, has_downloads) in rows {
            let Some(release_date) = extract_release_date(metadata_json.as_deref()) else {
                continue;
            };
            if release_date < start || release_date > end {
                continue;
            }
            entries.push(CalendarEntry {
                id: id.clone(),
                kind: "movie".to_owned(),
                air_date: release_date.format("%Y-%m-%d").to_string(),
                title: title.clone(),
                season_number: None,
                episode_number: None,
                media_item_id: id,
                media_item_title: title,
                media_item_type: Some("movie".to_owned()),
                has_files: has_files != 0,
                has_downloads: has_downloads != 0,
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
