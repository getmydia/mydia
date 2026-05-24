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
    use mydia_rs_db::DatabaseConnection;
    use mydia_rs_entities::{downloads, episodes, media_files, media_items};
    use sea_orm::entity::prelude::*;
    use sea_orm::query::{QueryOrder, QuerySelect};
    use std::collections::HashSet;

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

    async fn count_media_type(
        db: &DatabaseConnection,
        media_type: &str,
    ) -> Result<i64, ServerFnError> {
        let n = media_items::Entity::find()
            .filter(media_items::Column::Type.eq(media_type.to_owned()))
            .count(db)
            .await
            .map_err(|err| ServerFnError::new(format!("count {media_type}: {err}")))?;
        Ok(i64::try_from(n).unwrap_or(i64::MAX))
    }

    async fn count_active_downloads(db: &DatabaseConnection) -> Result<i64, ServerFnError> {
        // See the Phoenix doc comment in the prior implementation —
        // active := imported_at IS NULL AND completed_at IS NULL AND
        // import_failed_at IS NULL.
        let n = downloads::Entity::find()
            .filter(downloads::Column::ImportedAt.is_null())
            .filter(downloads::Column::CompletedAt.is_null())
            .filter(downloads::Column::ImportFailedAt.is_null())
            .count(db)
            .await
            .map_err(|err| ServerFnError::new(format!("count active downloads: {err}")))?;
        Ok(i64::try_from(n).unwrap_or(i64::MAX))
    }

    async fn total_storage_bytes(db: &DatabaseConnection) -> Result<i64, ServerFnError> {
        // Phoenix uses `sum(size)` with a fallback to 0. SeaORM aggregate
        // helpers are clunky for nullable sums; pull the sizes and add
        // in Rust. The row count is bounded by the library size which is
        // tractable for a dashboard widget.
        let sizes = media_files::Entity::find()
            .select_only()
            .column(media_files::Column::Size)
            .filter(media_files::Column::TrashedAt.is_null())
            .into_tuple::<Option<i64>>()
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("total storage: {err}")))?;
        Ok(sizes.into_iter().flatten().sum::<i64>())
    }

    async fn list_episodes_by_air_date(
        db: &DatabaseConnection,
        start: chrono::NaiveDate,
        end: chrono::NaiveDate,
        limit: i64,
    ) -> Result<Vec<DashboardEpisode>, ServerFnError> {
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

        let media_item_ids: Vec<_> = eps.iter().map(|e| e.media_item_id.clone()).collect();
        let parents = media_items::Entity::find()
            .filter(media_items::Column::Id.is_in(media_item_ids))
            .filter(media_items::Column::Monitored.eq(true))
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
            .filter(media_files::Column::EpisodeId.is_in(episode_ids))
            .into_tuple::<Option<mydia_rs_db::types::UuidText>>()
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("query media_files: {err}")))?;
        let files_set: HashSet<_> = files.into_iter().flatten().collect();

        let limit_usize = usize::try_from(limit).unwrap_or(usize::MAX);
        let mut out: Vec<DashboardEpisode> = Vec::new();
        for e in eps {
            if out.len() >= limit_usize {
                break;
            }
            let Some(parent) = parent_map.get(&e.media_item_id) else {
                continue;
            };
            let Some(ad) = e.air_date else { continue };
            out.push(DashboardEpisode {
                id: e.id.to_string(),
                air_date: ad.format("%Y-%m-%d").to_string(),
                title: e.title.clone(),
                season_number: Some(i64::from(e.season_number)),
                episode_number: Some(i64::from(e.episode_number)),
                media_item_id: parent.id.to_string(),
                media_item_title: Some(parent.title.clone()),
                has_files: files_set.contains(&e.id),
            });
        }
        out.sort_by(|a, b| {
            a.air_date
                .cmp(&b.air_date)
                .then_with(|| a.media_item_title.cmp(&b.media_item_title))
        });
        Ok(out)
    }
}
