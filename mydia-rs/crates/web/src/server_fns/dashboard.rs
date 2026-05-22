//! Dashboard server functions (U24.e).
//!
//! Mirror of `MydiaWeb.DashboardLive.Index`'s read path: the small set
//! of counts the operator wants at a glance plus the seven-day
//! recent/upcoming episode lists keyed off `monitored: true`. Trending
//! titles from the metadata-relay are deferred to a follow-up — they
//! require the registry to be wired into `WebState`, which is itself a
//! separate plumbing step.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Aggregate library counters surfaced on the dashboard "at a glance"
/// strip. Each field maps 1:1 to the Phoenix call it replaces.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DashboardStats {
    /// `Mydia.Media.count_movies/0`
    pub movie_count: i64,
    /// `Mydia.Media.count_tv_shows/0`
    pub tv_show_count: i64,
    /// `Mydia.Downloads.count_active_downloads/0`
    pub active_downloads_count: i64,
    /// `Mydia.Library.total_storage_bytes/0` — raw bytes; the page
    /// formats this for display.
    pub total_storage_bytes: i64,
}

/// One row from the recent/upcoming episode lists, mirroring the
/// `CalendarEntry` flat fields the dashboard template renders. Only
/// the fields the at-a-glance widget actually shows are included; the
/// fuller `CalendarEntry` shape lives behind the calendar page (U27).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DashboardEpisode {
    pub id: String,
    pub air_date: String,
    pub title: Option<String>,
    pub season_number: Option<i64>,
    pub episode_number: Option<i64>,
    pub media_item_id: String,
    pub media_item_title: Option<String>,
    pub has_files: bool,
}

#[get("/api/dashboard/stats")]
pub async fn dashboard_stats() -> Result<DashboardStats, ServerFnError> {
    server::stats().await
}

#[get("/api/dashboard/recent")]
pub async fn recent_episodes() -> Result<Vec<DashboardEpisode>, ServerFnError> {
    server::recent().await
}

#[get("/api/dashboard/upcoming")]
pub async fn upcoming_episodes() -> Result<Vec<DashboardEpisode>, ServerFnError> {
    server::upcoming().await
}

#[cfg(feature = "server")]
mod server {
    use super::{DashboardEpisode, DashboardStats};
    use crate::server_fns::auth::require_session_user_id;
    use crate::server_state::WebState;
    use chrono::{Duration as ChronoDuration, Utc};
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_db::Db;

    fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    pub(super) async fn stats() -> Result<DashboardStats, ServerFnError> {
        // Even though the read endpoints are largely safe to leak, the
        // dashboard renders a single user's view of the library — gate
        // the surface to authenticated users.
        require_session_user_id().await?;
        let st = state()?;

        let (movies, tv, downloads, bytes) = futures::future::join4(
            count_media_type(&st.db, "movie"),
            count_media_type(&st.db, "tv_show"),
            count_active_downloads(&st.db),
            total_storage_bytes(&st.db),
        )
        .await;

        Ok(DashboardStats {
            movie_count: movies?,
            tv_show_count: tv?,
            active_downloads_count: downloads?,
            total_storage_bytes: bytes?,
        })
    }

    pub(super) async fn recent() -> Result<Vec<DashboardEpisode>, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;
        let today = Utc::now().date_naive();
        let seven_days_ago = today - ChronoDuration::days(7);
        list_episodes_by_air_date(&st.db, seven_days_ago, today, 10).await
    }

    pub(super) async fn upcoming() -> Result<Vec<DashboardEpisode>, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;
        let today = Utc::now().date_naive();
        let seven_days_ahead = today + ChronoDuration::days(7);
        list_episodes_by_air_date(&st.db, today, seven_days_ahead, 10).await
    }

    async fn count_media_type(db: &Db, media_type: &str) -> Result<i64, ServerFnError> {
        let (n,): (i64,) = match db {
            Db::Sqlite(pool) => sqlx::query_as("SELECT COUNT(*) FROM media_items WHERE type = ?")
                .bind(media_type)
                .fetch_one(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("count {media_type}: {err}")))?,
            Db::Postgres(pool) => {
                sqlx::query_as("SELECT COUNT(*) FROM media_items WHERE type = $1")
                    .bind(media_type)
                    .fetch_one(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("count {media_type}: {err}")))?
            }
        };
        Ok(n)
    }

    async fn count_active_downloads(db: &Db) -> Result<i64, ServerFnError> {
        // Active is the predicate from `Mydia.Downloads.History`:
        // imported_at IS NULL and status is in the active set.
        // We compute it in SQL (rather than `list + len()`) because
        // the dashboard widget reads it on every render and we don't
        // want to materialize every row.
        let (n,): (i64,) = match db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT COUNT(*) FROM downloads \
                 WHERE imported_at IS NULL \
                 AND status IN ('downloading', 'seeding', 'checking', 'paused', 'queued')",
            )
            .fetch_one(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("count active downloads: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT COUNT(*) FROM downloads \
                 WHERE imported_at IS NULL \
                 AND status IN ('downloading', 'seeding', 'checking', 'paused', 'queued')",
            )
            .fetch_one(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("count active downloads: {err}")))?,
        };
        Ok(n)
    }

    async fn total_storage_bytes(db: &Db) -> Result<i64, ServerFnError> {
        // Phoenix uses `sum(size)` cast to integer with a fallback to
        // 0. sqlx returns Option<i64> from a SUM over an empty
        // selection; coerce with unwrap_or(0).
        let (raw,): (Option<i64>,) = match db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT COALESCE(SUM(size), 0) FROM media_files WHERE trashed_at IS NULL",
            )
            .fetch_one(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("total storage: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT COALESCE(SUM(size), 0)::bigint FROM media_files WHERE trashed_at IS NULL",
            )
            .fetch_one(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("total storage: {err}")))?,
        };
        Ok(raw.unwrap_or(0))
    }

    async fn list_episodes_by_air_date(
        db: &Db,
        start: chrono::NaiveDate,
        end: chrono::NaiveDate,
        limit: i64,
    ) -> Result<Vec<DashboardEpisode>, ServerFnError> {
        // Mirrors the join + EXISTS expression in the Phoenix
        // implementation, but we only fetch the fields the dashboard
        // widget renders. The HAS_FILES EXISTS keeps the row light
        // even though it touches `media_files`.
        type Row = (
            String,
            chrono::NaiveDate,
            Option<String>,
            Option<i64>,
            Option<i64>,
            String,
            Option<String>,
            i64,
        );
        let rows: Vec<Row> = match db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT e.id, e.air_date, e.title, e.season_number, e.episode_number, \
                        m.id, m.title, \
                        CASE WHEN EXISTS(SELECT 1 FROM media_files WHERE episode_id = e.id) \
                             THEN 1 ELSE 0 END \
                 FROM episodes e \
                 INNER JOIN media_items m ON e.media_item_id = m.id \
                 WHERE e.air_date IS NOT NULL \
                   AND e.air_date >= ? AND e.air_date <= ? \
                   AND m.monitored = 1 \
                 ORDER BY e.air_date ASC, m.title ASC \
                 LIMIT ?",
            )
            .bind(start)
            .bind(end)
            .bind(limit)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("list episodes: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT e.id, e.air_date, e.title, e.season_number, e.episode_number, \
                        m.id, m.title, \
                        CASE WHEN EXISTS(SELECT 1 FROM media_files WHERE episode_id = e.id) \
                             THEN 1 ELSE 0 END \
                 FROM episodes e \
                 INNER JOIN media_items m ON e.media_item_id = m.id \
                 WHERE e.air_date IS NOT NULL \
                   AND e.air_date >= $1 AND e.air_date <= $2 \
                   AND m.monitored = true \
                 ORDER BY e.air_date ASC, m.title ASC \
                 LIMIT $3",
            )
            .bind(start)
            .bind(end)
            .bind(limit)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("list episodes: {err}")))?,
        };
        Ok(rows
            .into_iter()
            .map(|(id, ad, title, s, e, mid, mtitle, has)| DashboardEpisode {
                id,
                air_date: ad.format("%Y-%m-%d").to_string(),
                title,
                season_number: s,
                episode_number: e,
                media_item_id: mid,
                media_item_title: mtitle,
                has_files: has != 0,
            })
            .collect())
    }
}
