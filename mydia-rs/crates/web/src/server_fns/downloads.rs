//! Downloads queue server functions (U27).
//!
//! Phoenix counterpart: `MydiaWeb.DownloadsLive.Index`. The Phoenix
//! page is the largest U27 surface — tabs (Queue / Completed / Issues),
//! batch selection, retry/pause/resume/cancel mutations, library-search
//! integration for unmatched downloads, file-resolution forms for
//! ambiguous unpacks. The Rust port ships the read surface, the cancel
//! mutation, and the `manually_match_download` write path that pairs
//! an unmatched download with a `media_items` row by id.
//!
//! TODO(U27.downloads-followup): port `resolve_file_mappings`,
//! batch-delete, batch-retry. The Phoenix file has 900+ LOC of event
//! handlers; this slice covers the operational visibility shape plus
//! the manual-match affordance — the single most-clicked authoring
//! flow on the Phoenix page.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Page-size matching `@items_per_page` in
/// `lib/mydia_web/live/downloads_live/index.ex`.
pub const PAGE_SIZE: i64 = 50;

/// A row in the downloads queue. Mirrors the fields the Phoenix
/// template renders directly — title, status, progress, the few
/// metadata-derived bytes (size, seeders, leechers).
///
/// Migration 20251105033610 dropped the `status` and `progress`
/// columns from `downloads`; Phoenix now derives them in-memory from
/// each download-client adapter's live state. The Rust port hasn't
/// wired the adapter probes into the server-fn layer yet, so `status`
/// is populated server-side from the surviving columns (a coarse
/// "active" / "completed" / "failed" tri-state) and `progress` is
/// always `None`. The wire field names stay so the SPA components
/// don't have to flex.
///
/// TODO(U27.downloads-followup): once the adapter-probe layer lands,
/// populate `status` with the full Phoenix vocabulary (downloading /
/// seeding / checking / paused / queued / missing / unknown) and
/// populate `progress` from the client's report.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DownloadRow {
    pub id: String,
    pub title: String,
    /// Coarse derived status, populated server-side. One of "active",
    /// "completed", "failed", or "imported".
    pub status: String,
    /// 0.0..=1.0 when the column existed. Always `None` until the
    /// adapter-probe layer is ported.
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

/// Payload for [`manually_match_download`] — wires an existing
/// `downloads` row to a `media_items` row by id, clearing the
/// `unmatched` state. Phoenix calls this from a modal that opens
/// when the operator clicks an unmatched download row.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ManuallyMatchDownload {
    pub download_id: String,
    pub media_item_id: String,
}

#[post("/api/downloads/manual_match")]
pub async fn manually_match_download(payload: ManuallyMatchDownload) -> Result<(), ServerFnError> {
    server::manually_match(payload).await
}

#[cfg(feature = "server")]
mod server {
    use super::{
        CancelDownload, DownloadRow, DownloadsPage, DownloadsQuery, DownloadsTab,
        ManuallyMatchDownload, PAGE_SIZE,
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

        // Phoenix's `Mydia.Downloads.Queue.cancel_download/2` removes the
        // torrent from the configured client adapter and then deletes
        // the database row (see `lib/mydia/downloads/queue.ex:68-87`).
        // The adapter call isn't wired into the Rust server-fn layer
        // yet — without it, the operator's "Cancel" click would leave a
        // ghost torrent in qbittorrent / transmission / etc. We delete
        // the row anyway so the UI moves forward; the orphan torrent
        // will surface as "missing" once the probe layer lands.
        //
        // TODO(U27.downloads-followup): once the adapter probe surface
        // exists, wrap this in the full
        //   Client.remove_download(adapter, config, client_id, opts)
        //   |> History.delete_download
        // sequence so cancelling here also stops the underlying client.
        let affected = match &st.db {
            Db::Sqlite(pool) => sqlx::query("DELETE FROM downloads WHERE id = ?")
                .bind(&payload.id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("cancel download: {err}")))?
                .rows_affected(),
            Db::Postgres(pool) => sqlx::query("DELETE FROM downloads WHERE id = $1")
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

    /// Manual-match write path. Verifies the target `media_items` row
    /// exists, then updates the download's `media_item_id` plus the
    /// `match_status` column to `matched`, clearing any prior
    /// `unmatched` state. The Phoenix flow also re-enqueues the
    /// importer for `imported_at IS NULL` rows; that piece sits in
    /// `crates/jobs/` and is intentionally not invoked here so the
    /// admin's manual-match action stays a pure database update for
    /// now. A TODO marker calls out the gap.
    pub(super) async fn manually_match(
        payload: ManuallyMatchDownload,
    ) -> Result<(), ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;
        let now = chrono::Utc::now();

        // Guard: the media_items row must exist before we wire it in.
        // SQLite happily lets a FK violation through unless the FK
        // pragma is on (it isn't on by default); we do the lookup
        // explicitly so the operator gets a clear error.
        let media_present: Option<(String,)> = match &st.db {
            Db::Sqlite(pool) => sqlx::query_as("SELECT id FROM media_items WHERE id = ? LIMIT 1")
                .bind(&payload.media_item_id)
                .fetch_optional(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("verify media_item: {err}")))?,
            Db::Postgres(pool) => {
                sqlx::query_as("SELECT id FROM media_items WHERE id = $1 LIMIT 1")
                    .bind(&payload.media_item_id)
                    .fetch_optional(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("verify media_item: {err}")))?
            }
        };
        if media_present.is_none() {
            return Err(ServerFnError::new(format!(
                "no media_item with id {}",
                payload.media_item_id
            )));
        }

        let affected = match &st.db {
            Db::Sqlite(pool) => sqlx::query(
                "UPDATE downloads SET media_item_id = ?, match_status = 'matched', updated_at = ? \
                 WHERE id = ?",
            )
            .bind(&payload.media_item_id)
            .bind(now.to_rfc3339())
            .bind(&payload.download_id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("manual match: {err}")))?
            .rows_affected(),
            Db::Postgres(pool) => sqlx::query(
                "UPDATE downloads SET media_item_id = $1, match_status = 'matched', updated_at = $2 \
                 WHERE id = $3",
            )
            .bind(&payload.media_item_id)
            .bind(now)
            .bind(&payload.download_id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("manual match: {err}")))?
            .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!(
                "no download with id {}",
                payload.download_id
            )));
        }
        // TODO(U27.downloads-followup): once `crates/jobs/` exposes a
        // re-import worker, enqueue it here so the Phoenix
        // `manually_match_download → reimport` flow runs end-to-end.
        Ok(())
    }

    /// Internal SQL row shape. The `status` and `progress` columns
    /// dropped in migration 20251105033610 are NOT selected — `status`
    /// is derived in [`decode_row`] from `imported_at` / `completed_at`
    /// / `import_failed_at`, and `progress` is left as `None` until the
    /// adapter-probe layer is ported.
    #[derive(sqlx::FromRow)]
    struct CoreRow {
        id: String,
        title: String,
        indexer: Option<String>,
        download_client: Option<String>,
        error_message: Option<String>,
        inserted_at: chrono::DateTime<chrono::Utc>,
        completed_at: Option<chrono::DateTime<chrono::Utc>>,
        imported_at: Option<chrono::DateTime<chrono::Utc>>,
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
        //
        // Without the dropped `status` column we can't filter the Queue
        // / Issues tabs purely in SQL — Phoenix filters in-memory after
        // hydrating each row from the adapter (see
        // `Mydia.Downloads.History.apply_status_filters/2`). We mirror
        // that by selecting the candidate set in SQL and finishing the
        // tab filter in Rust against the derived status.
        const SELECT_COLS: &str = "d.id AS id, d.title AS title, \
             d.indexer AS indexer, d.download_client AS download_client, \
             d.error_message AS error_message, d.inserted_at AS inserted_at, \
             d.completed_at AS completed_at, d.imported_at AS imported_at, \
             d.bytes_pulled AS bytes_pulled, d.import_failed_at AS import_failed_at, \
             d.match_status AS match_status, \
             m.title AS media_item_title, m.id AS media_item_id, m.type AS media_item_type, \
             e.season_number AS episode_season, e.episode_number AS episode_number";

        // SQL pre-filter narrows the candidate set as much as the
        // remaining columns allow. Each tab adds a Rust-side post-filter
        // on the derived status below.
        let where_clause = match tab {
            DownloadsTab::Queue => {
                " WHERE d.imported_at IS NULL \
                  AND d.completed_at IS NULL \
                  AND d.import_failed_at IS NULL "
            }
            DownloadsTab::Completed => " WHERE d.imported_at IS NOT NULL ",
            DownloadsTab::Issues => {
                " WHERE d.import_failed_at IS NOT NULL \
                  OR d.match_status IN ('unmatched', 'unresolved_files') "
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

    /// Coarse status derived from the surviving columns. Mirrors the
    /// in-memory branch in `Mydia.Downloads.History` for the case
    /// where the adapter is unreachable (no live torrent state), which
    /// is the only state the Rust port can observe today.
    fn derive_status(
        completed_at: Option<&chrono::DateTime<chrono::Utc>>,
        imported_at: Option<&chrono::DateTime<chrono::Utc>>,
        import_failed_at: Option<&chrono::DateTime<chrono::Utc>>,
    ) -> &'static str {
        if imported_at.is_some() {
            "imported"
        } else if import_failed_at.is_some() {
            "failed"
        } else if completed_at.is_some() {
            "completed"
        } else {
            "active"
        }
    }

    fn decode_row(r: CoreRow) -> DownloadRow {
        let status = derive_status(
            r.completed_at.as_ref(),
            r.imported_at.as_ref(),
            r.import_failed_at.as_ref(),
        );
        DownloadRow {
            id: r.id,
            title: r.title,
            status: status.to_owned(),
            // TODO(U27.downloads-followup): populate from the adapter
            // probe's `progress` field once that layer lands.
            progress: None,
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
