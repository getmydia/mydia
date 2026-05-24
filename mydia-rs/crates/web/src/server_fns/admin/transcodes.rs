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
    use mydia_rs_db::types::{DateTimeSecs, UuidText};
    use mydia_rs_db::DatabaseConnection;
    use mydia_rs_entities::{media_files, transcode_jobs};
    use sea_orm::entity::prelude::*;
    use sea_orm::query::QueryOrder;
    use sea_orm::sea_query::{Expr, ExprTrait};

    async fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context".to_owned()))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState axum extension missing".to_owned()))
    }

    fn parse_uuid(s: &str) -> Option<UuidText> {
        uuid::Uuid::parse_str(s).ok().map(UuidText::from)
    }

    pub(super) async fn list() -> Result<Vec<TranscodeRow>, ServerFnError> {
        let _user_id = require_admin_user_id().await?;
        let state = state().await?;

        let jobs = transcode_jobs::Entity::find()
            .order_by_desc(transcode_jobs::Column::InsertedAt)
            .all(&state.db)
            .await
            .map_err(|err| ServerFnError::new(format!("query transcode_jobs: {err}")))?;

        if jobs.is_empty() {
            return Ok(Vec::new());
        }

        // Bulk-load the referenced media files for a cheap "file name"
        // column on the page (Phoenix preloads :media_file with a
        // nilable association — we do the same with a hash lookup).
        let file_ids: Vec<_> = jobs.iter().map(|j| j.media_file_id.clone()).collect();
        let files = media_files::Entity::find()
            .filter(media_files::Column::Id.is_in(file_ids))
            .all(&state.db)
            .await
            .map_err(|err| ServerFnError::new(format!("query media_files: {err}")))?;
        let mut file_map = std::collections::HashMap::new();
        for f in files {
            file_map.insert(f.id.clone(), f.path);
        }

        Ok(jobs
            .into_iter()
            .map(|j| {
                let media_file_name = file_map.get(&j.media_file_id).cloned().flatten().map(|p| {
                    std::path::Path::new(&p)
                        .file_name()
                        .map_or_else(|| p.clone(), |s| s.to_string_lossy().into_owned())
                });
                TranscodeRow {
                    id: j.id.to_string(),
                    media_file_id: j.media_file_id.to_string(),
                    media_file_name,
                    resolution: j.resolution,
                    status: j.status,
                    progress: j.progress,
                    error: j.error,
                    started_at: j.started_at.map(|dt| dt.0.to_rfc3339()),
                }
            })
            .collect())
    }

    pub(super) async fn cancel(id: String) -> Result<(), ServerFnError> {
        let _user_id = require_admin_user_id().await?;
        let state = state().await?;

        let Some(wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new(format!("invalid transcode_job id {id}")));
        };
        let now = DateTimeSecs::from(chrono::Utc::now());
        let backend = state.db.get_database_backend();
        let res = transcode_jobs::Entity::update_many()
            .col_expr(
                transcode_jobs::Column::Status,
                Expr::value("cancelled".to_owned()),
            )
            .col_expr(
                transcode_jobs::Column::UpdatedAt,
                now.into_simple_expr(backend),
            )
            .filter(Expr::col(transcode_jobs::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(&state.db)
            .await
            .map_err(|err| ServerFnError::new(format!("update transcode: {err}")))?;
        if res.rows_affected == 0 {
            return Err(ServerFnError::new(format!("no transcode_job with id {id}")));
        }
        Ok(())
    }
}
