//! Active-transcodes server functions.
//!
//! Phoenix counterpart: `MydiaWeb.TranscodesLive.Index` +
//! `Mydia.Downloads.list_transcode_jobs/1`. The page lists every
//! current `transcode_jobs` row with its media-file name, status,
//! and progress, and offers a cancel action per row.
//!
//! `transcode_jobs` schema (see
//! `priv/repo/migrations/20251226204340_create_transcode_jobs.exs`):
//! `id`, `media_file_id`, `resolution`, `status`, `progress`,
//! `output_path`, `file_size`, `error`, `started_at`, `completed_at`,
//! `last_accessed_at`, `inserted_at`, `updated_at`.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TranscodeRow {
    pub id: String,
    pub media_file_id: String,
    /// Optional convenience: the media file's basename for display.
    /// `None` when the join failed (media file deleted).
    #[serde(default)]
    pub media_file_name: Option<String>,
    pub resolution: String,
    pub status: String,
    #[serde(default)]
    pub progress: Option<f64>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub started_at: Option<String>,
}

#[get("/api/admin/transcodes")]
pub async fn list_transcodes() -> Result<Vec<TranscodeRow>, ServerFnError> {
    server::list().await
}

#[post("/api/admin/transcodes/cancel")]
pub async fn cancel_transcode(id: String) -> Result<(), ServerFnError> {
    server::cancel(id).await
}

#[cfg(feature = "server")]
mod server {
    use super::TranscodeRow;
    use crate::server_fns::auth::require_admin_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use mydia_rs_db::Db;

    async fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context".to_owned()))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState axum extension missing".to_owned()))
    }

    type TranscodeTuple = (
        String,
        String,
        Option<String>,
        String,
        String,
        Option<f64>,
        Option<String>,
        Option<chrono::DateTime<chrono::Utc>>,
    );

    pub(super) async fn list() -> Result<Vec<TranscodeRow>, ServerFnError> {
        let _user_id = require_admin_user_id().await?;
        let state = state().await?;

        // LEFT JOIN so a transcode row whose media_file went away
        // still renders. The Phoenix page does the same by preloading
        // `:media_file` with a nilable association.
        let rows: Vec<TranscodeTuple> = match &state.db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT t.id, t.media_file_id, mf.file_name, t.resolution, t.status, \
                        t.progress, t.error, t.started_at \
                 FROM transcode_jobs t \
                 LEFT JOIN media_files mf ON mf.id = t.media_file_id \
                 ORDER BY t.inserted_at DESC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query transcode_jobs: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT t.id, t.media_file_id, mf.file_name, t.resolution, t.status, \
                        t.progress, t.error, t.started_at \
                 FROM transcode_jobs t \
                 LEFT JOIN media_files mf ON mf.id = t.media_file_id \
                 ORDER BY t.inserted_at DESC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query transcode_jobs: {err}")))?,
        };

        Ok(rows
            .into_iter()
            .map(
                |(
                    id,
                    media_file_id,
                    media_file_name,
                    resolution,
                    status,
                    progress,
                    error,
                    started_at,
                )| TranscodeRow {
                    id,
                    media_file_id,
                    media_file_name,
                    resolution,
                    status,
                    progress,
                    error,
                    started_at: started_at.map(|dt| dt.to_rfc3339()),
                },
            )
            .collect())
    }

    pub(super) async fn cancel(id: String) -> Result<(), ServerFnError> {
        let _user_id = require_admin_user_id().await?;
        let state = state().await?;

        // Soft cancel: mark the row `cancelled`. The transcode worker
        // checks this status on each progress tick and aborts when it
        // observes the change. Mirrors Phoenix's
        // `Mydia.Downloads.cancel_transcode_job/1`.
        let affected = match &state.db {
            Db::Sqlite(pool) => sqlx::query(
                "UPDATE transcode_jobs SET status = 'cancelled', updated_at = ? WHERE id = ?",
            )
            .bind(chrono::Utc::now().to_rfc3339())
            .bind(&id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("update transcode: {err}")))?
            .rows_affected(),
            Db::Postgres(pool) => sqlx::query(
                "UPDATE transcode_jobs SET status = 'cancelled', updated_at = $1 WHERE id = $2",
            )
            .bind(chrono::Utc::now())
            .bind(&id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("update transcode: {err}")))?
            .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!("no transcode_job with id {id}")));
        }
        Ok(())
    }
}
