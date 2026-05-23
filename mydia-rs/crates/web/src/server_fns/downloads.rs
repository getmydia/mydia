//! Downloads queue server functions (U27).
//!
//! Phoenix counterpart: `MydiaWeb.DownloadsLive.Index`. The Phoenix
//! page is the largest U27 surface — tabs (Queue / Completed / Issues),
//! batch selection, retry/pause/resume/cancel mutations, library-search
//! integration for unmatched downloads, file-resolution forms for
//! ambiguous unpacks. The Rust port ships the read surface plus the
//! cancel mutation; the richer authoring flows (manual match, file
//! resolution) follow once `crates/downloads/` exposes those calls
//! end-to-end.
//!
//! TODO(U27.downloads-followup): port `manually_match_download`,
//! `resolve_file_mappings`, batch-delete, batch-retry. The Phoenix
//! file has 900+ LOC of event handlers; bringing them across in one
//! commit would dwarf the rest of U27. Operators get the visibility
//! shape — list + cancel + pubsub-driven progress — in this slice.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Page-size matching `@items_per_page` in
/// `lib/mydia_web/live/downloads_live/index.ex`.
pub const PAGE_SIZE: i64 = 50;

/// A row in the downloads queue. Mirrors the fields the Phoenix
/// template renders directly — title, status, progress, the few
/// metadata-derived bytes (size, seeders, leechers).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DownloadRow {
    pub id: String,
    pub title: String,
    pub status: String,
    /// 0.0..=1.0 (matches Phoenix's `progress` column). The UI scales
    /// to 0..=100 for the progress bar.
    pub progress: Option<f64>,
    pub indexer: Option<String>,
    pub download_client: Option<String>,
    pub error_message: Option<String>,
    pub inserted_at: String,
    pub completed_at: Option<String>,
    /// Title of the parent show / movie if associated.
    pub media_item_title: Option<String>,
    pub media_item_id: Option<String>,
    pub media_item_type: Option<String>,
    pub episode_season: Option<i64>,
    pub episode_number: Option<i64>,
    /// Bytes downloaded so far (when the client reports it).
    pub bytes_pulled: Option<i64>,
    pub import_failed_at: Option<String>,
    pub match_status: Option<String>,
}

/// Tab discriminator on the page — Queue (active) / Completed
/// (imported) / Issues (unmatched / unresolved / failed).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum DownloadsTab {
    #[default]
    Queue,
    Completed,
    Issues,
}

impl DownloadsTab {
    #[must_use]
    pub fn parse(s: &str) -> Self {
        match s {
            "completed" => Self::Completed,
            "issues" => Self::Issues,
            _ => Self::Queue,
        }
    }

    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Queue => "queue",
            Self::Completed => "completed",
            Self::Issues => "issues",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DownloadsQuery {
    pub tab: String,
    #[serde(default)]
    pub page: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DownloadsPage {
    pub rows: Vec<DownloadRow>,
    pub has_more: bool,
}

#[get("/api/downloads")]
pub async fn list_downloads(query: DownloadsQuery) -> Result<DownloadsPage, ServerFnError> {
    server::list(query).await
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CancelDownload {
    pub id: String,
}

#[post("/api/downloads/cancel")]
pub async fn cancel_download(payload: CancelDownload) -> Result<(), ServerFnError> {
    server::cancel(payload).await
}

#[cfg(feature = "server")]
mod server {
    use super::{
        CancelDownload, DownloadRow, DownloadsPage, DownloadsQuery, DownloadsTab, PAGE_SIZE,
    };
    use crate::server_fns::auth::require_session_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_db::Db;

    fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    pub(super) async fn list(query: DownloadsQuery) -> Result<DownloadsPage, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;

        let tab = DownloadsTab::parse(&query.tab);
        let page = query.page.max(0);
        let offset = page * PAGE_SIZE;
        let limit = PAGE_SIZE + 1;

        let rows = fetch_rows(&st.db, tab, offset, limit).await?;
        let has_more = rows.len() as i64 > PAGE_SIZE;
        Ok(DownloadsPage {
            rows: rows.into_iter().take(PAGE_SIZE as usize).collect(),
            has_more,
        })
    }

    pub(super) async fn cancel(payload: CancelDownload) -> Result<(), ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;
        let now = chrono::Utc::now();

        let affected = match &st.db {
            Db::Sqlite(pool) => sqlx::query(
                "UPDATE downloads SET status = 'cancelled', updated_at = ? WHERE id = ?",
            )
            .bind(now.to_rfc3339())
            .bind(&payload.id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("cancel download: {err}")))?
            .rows_affected(),
            Db::Postgres(pool) => sqlx::query(
                "UPDATE downloads SET status = 'cancelled', updated_at = $1 WHERE id = $2",
            )
            .bind(now)
            .bind(&payload.id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("cancel download: {err}")))?
            .rows_affected(),
        };

        if affected == 0 {
            return Err(ServerFnError::new(format!(
                "no download with id {}",
                payload.id
            )));
        }
        Ok(())
    }

    /// Internal SQL row shape — sqlx only derives `FromRow` for tuples
    /// up to 16 columns and we need 17 (downloads + the joined
    /// `media_item` / episode columns), so the row is materialized
    /// into a named struct instead. The decoder transposes it into a
    /// [`DownloadRow`] on the way out.
    #[derive(sqlx::FromRow)]
    struct CoreRow {
        id: String,
        title: String,
        status: String,
        progress: Option<f64>,
        indexer: Option<String>,
        download_client: Option<String>,
        error_message: Option<String>,
        inserted_at: chrono::DateTime<chrono::Utc>,
        completed_at: Option<chrono::DateTime<chrono::Utc>>,
        bytes_pulled: Option<i64>,
        import_failed_at: Option<chrono::DateTime<chrono::Utc>>,
        match_status: Option<String>,
        media_item_title: Option<String>,
        media_item_id: Option<String>,
        media_item_type: Option<String>,
        episode_season: Option<i64>,
        episode_number: Option<i64>,
    }

    async fn fetch_rows(
        db: &Db,
        tab: DownloadsTab,
        offset: i64,
        limit: i64,
    ) -> Result<Vec<DownloadRow>, ServerFnError> {
        // Column aliases lift the joined columns into stable names so
        // the `FromRow` derive can find them regardless of the join
        // shape.
        const SELECT_COLS: &str = "d.id AS id, d.title AS title, d.status AS status, \
             d.progress AS progress, d.indexer AS indexer, \
             d.download_client AS download_client, d.error_message AS error_message, \
             d.inserted_at AS inserted_at, d.completed_at AS completed_at, \
             d.bytes_pulled AS bytes_pulled, d.import_failed_at AS import_failed_at, \
             d.match_status AS match_status, \
             m.title AS media_item_title, m.id AS media_item_id, m.type AS media_item_type, \
             e.season_number AS episode_season, e.episode_number AS episode_number";

        let where_clause = match tab {
            DownloadsTab::Queue => {
                " WHERE d.imported_at IS NULL \
                  AND d.status IN ('downloading', 'seeding', 'checking', 'paused', 'queued') "
            }
            DownloadsTab::Completed => " WHERE d.imported_at IS NOT NULL ",
            DownloadsTab::Issues => {
                " WHERE d.status IN ('failed', 'missing') \
                  OR d.match_status IN ('unmatched', 'unresolved_files') \
                  OR d.import_failed_at IS NOT NULL "
            }
        };

        let rows: Vec<CoreRow> = match db {
            Db::Sqlite(pool) => {
                let sql = format!(
                    "SELECT {SELECT_COLS} \
                     FROM downloads d \
                     LEFT JOIN media_items m ON m.id = d.media_item_id \
                     LEFT JOIN episodes e ON e.id = d.episode_id \
                     {where_clause} \
                     ORDER BY d.inserted_at DESC LIMIT ? OFFSET ?"
                );
                sqlx::query_as(&sql)
                    .bind(limit)
                    .bind(offset)
                    .fetch_all(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("list downloads: {err}")))?
            }
            Db::Postgres(pool) => {
                let sql = format!(
                    "SELECT {SELECT_COLS} \
                     FROM downloads d \
                     LEFT JOIN media_items m ON m.id = d.media_item_id \
                     LEFT JOIN episodes e ON e.id = d.episode_id \
                     {where_clause} \
                     ORDER BY d.inserted_at DESC LIMIT $1 OFFSET $2"
                );
                sqlx::query_as(&sql)
                    .bind(limit)
                    .bind(offset)
                    .fetch_all(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("list downloads: {err}")))?
            }
        };

        Ok(rows.into_iter().map(decode_row).collect())
    }

    fn decode_row(r: CoreRow) -> DownloadRow {
        DownloadRow {
            id: r.id,
            title: r.title,
            status: r.status,
            progress: r.progress,
            indexer: r.indexer,
            download_client: r.download_client,
            error_message: r.error_message,
            inserted_at: r.inserted_at.to_rfc3339(),
            completed_at: r.completed_at.map(|dt| dt.to_rfc3339()),
            media_item_title: r.media_item_title,
            media_item_id: r.media_item_id,
            media_item_type: r.media_item_type,
            episode_season: r.episode_season,
            episode_number: r.episode_number,
            bytes_pulled: r.bytes_pulled,
            import_failed_at: r.import_failed_at.map(|dt| dt.to_rfc3339()),
            match_status: r.match_status,
        }
    }
}
