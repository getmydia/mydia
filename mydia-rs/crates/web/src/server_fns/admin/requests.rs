//! Media-request management server functions.
//!
//! Phoenix counterpart: `MydiaWeb.AdminRequestsLive.Index` +
//! `Mydia.MediaRequests`. The Phoenix page lists every
//! `media_requests` row filtered by status (default `"pending"`) and
//! exposes approve and reject mutations.
//!
//! `media_requests` schema (see
//! `priv/repo/migrations/20251108213827_create_media_requests.exs`):
//! `id`, `media_type`, `title`, `year`, `tmdb_id`, `imdb_id`,
//! `status`, `requester_notes`, `admin_notes`, `rejection_reason`,
//! `approved_at`, `rejected_at`, `requester_id`, `approved_by_id`,
//! `media_item_id`, `inserted_at`, `updated_at`.
//!
//! U28 ships the status updates only — the Phoenix-side approve flow
//! also enqueues a metadata-fetch job for newly-approved items. That
//! cross-domain side effect lands in a follow-up alongside the
//! approve-and-add-to-library worker.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RequestRow {
    pub id: String,
    pub media_type: String,
    pub title: String,
    #[serde(default)]
    pub year: Option<i32>,
    pub status: String,
    /// `users.username` of the requester. `None` when the user row
    /// has no username (OIDC-only accounts pre-display-name).
    #[serde(default)]
    pub requester_label: Option<String>,
    #[serde(default)]
    pub requester_notes: Option<String>,
    #[serde(default)]
    pub admin_notes: Option<String>,
    #[serde(default)]
    pub rejection_reason: Option<String>,
    pub inserted_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApproveRequest {
    pub id: String,
    #[serde(default)]
    pub admin_notes: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RejectRequest {
    pub id: String,
    pub rejection_reason: String,
    #[serde(default)]
    pub admin_notes: Option<String>,
}

#[get("/api/admin/requests")]
pub async fn list_requests(status: String) -> Result<Vec<RequestRow>, ServerFnError> {
    server::list(status).await
}

#[post("/api/admin/requests/approve")]
pub async fn approve_request(payload: ApproveRequest) -> Result<RequestRow, ServerFnError> {
    server::approve(payload).await
}

#[post("/api/admin/requests/reject")]
pub async fn reject_request(payload: RejectRequest) -> Result<RequestRow, ServerFnError> {
    server::reject(payload).await
}

#[cfg(feature = "server")]
mod server {
    use super::{ApproveRequest, RejectRequest, RequestRow};
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

    type RequestTuple = (
        String,
        String,
        String,
        Option<i32>,
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<chrono::DateTime<chrono::Utc>>,
    );

    pub(super) async fn list(status: String) -> Result<Vec<RequestRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let state = state().await?;

        // `status=""` or `status="all"` mean "no filter"; any other
        // value binds into the WHERE clause.
        let trimmed = status.trim();
        let status_filter = if trimmed.is_empty() || trimmed == "all" {
            None
        } else {
            Some(trimmed)
        };

        const SELECT_COLS: &str = "r.id, r.media_type, r.title, r.year, r.status, u.username, \
             r.requester_notes, r.admin_notes, r.rejection_reason, r.inserted_at";

        let rows: Vec<RequestTuple> = match (&state.db, status_filter) {
            (Db::Sqlite(pool), None) => sqlx::query_as(&format!(
                "SELECT {SELECT_COLS} \
                 FROM media_requests r \
                 LEFT JOIN users u ON u.id = r.requester_id \
                 ORDER BY r.inserted_at DESC"
            ))
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query media_requests: {err}")))?,
            (Db::Sqlite(pool), Some(filter)) => sqlx::query_as(&format!(
                "SELECT {SELECT_COLS} \
                 FROM media_requests r \
                 LEFT JOIN users u ON u.id = r.requester_id \
                 WHERE r.status = ? \
                 ORDER BY r.inserted_at DESC"
            ))
            .bind(filter)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query media_requests: {err}")))?,
            (Db::Postgres(pool), None) => sqlx::query_as(&format!(
                "SELECT {SELECT_COLS} \
                 FROM media_requests r \
                 LEFT JOIN users u ON u.id = r.requester_id \
                 ORDER BY r.inserted_at DESC"
            ))
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query media_requests: {err}")))?,
            (Db::Postgres(pool), Some(filter)) => sqlx::query_as(&format!(
                "SELECT {SELECT_COLS} \
                 FROM media_requests r \
                 LEFT JOIN users u ON u.id = r.requester_id \
                 WHERE r.status = $1 \
                 ORDER BY r.inserted_at DESC"
            ))
            .bind(filter)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query media_requests: {err}")))?,
        };

        Ok(rows
            .into_iter()
            .map(
                |(
                    id,
                    media_type,
                    title,
                    year,
                    status,
                    requester_label,
                    requester_notes,
                    admin_notes,
                    rejection_reason,
                    inserted_at,
                )| RequestRow {
                    id,
                    media_type,
                    title,
                    year,
                    status,
                    requester_label,
                    requester_notes,
                    admin_notes,
                    rejection_reason,
                    inserted_at: inserted_at.map(|dt| dt.to_rfc3339()),
                },
            )
            .collect())
    }

    pub(super) async fn approve(payload: ApproveRequest) -> Result<RequestRow, ServerFnError> {
        let acting = require_admin_user_id().await?;
        let state = state().await?;
        let now = chrono::Utc::now();

        let affected = match &state.db {
            Db::Sqlite(pool) => sqlx::query(
                "UPDATE media_requests SET status = 'approved', admin_notes = ?, \
                        approved_by_id = ?, approved_at = ?, updated_at = ? WHERE id = ?",
            )
            .bind(payload.admin_notes.as_deref())
            .bind(&acting)
            .bind(now.to_rfc3339())
            .bind(now.to_rfc3339())
            .bind(&payload.id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("approve request: {err}")))?
            .rows_affected(),
            Db::Postgres(pool) => sqlx::query(
                "UPDATE media_requests SET status = 'approved', admin_notes = $1, \
                        approved_by_id = $2, approved_at = $3, updated_at = $4 WHERE id = $5",
            )
            .bind(payload.admin_notes.as_deref())
            .bind(&acting)
            .bind(now)
            .bind(now)
            .bind(&payload.id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("approve request: {err}")))?
            .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!(
                "no media_request with id {}",
                payload.id
            )));
        }
        find_row(&payload.id).await
    }

    pub(super) async fn reject(payload: RejectRequest) -> Result<RequestRow, ServerFnError> {
        let acting = require_admin_user_id().await?;
        if payload.rejection_reason.trim().is_empty() {
            return Err(ServerFnError::new(
                "Rejection reason is required".to_owned(),
            ));
        }
        let state = state().await?;
        let now = chrono::Utc::now();

        let affected = match &state.db {
            Db::Sqlite(pool) => sqlx::query(
                "UPDATE media_requests SET status = 'rejected', rejection_reason = ?, \
                        admin_notes = ?, approved_by_id = ?, rejected_at = ?, updated_at = ? \
                 WHERE id = ?",
            )
            .bind(&payload.rejection_reason)
            .bind(payload.admin_notes.as_deref())
            .bind(&acting)
            .bind(now.to_rfc3339())
            .bind(now.to_rfc3339())
            .bind(&payload.id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("reject request: {err}")))?
            .rows_affected(),
            Db::Postgres(pool) => sqlx::query(
                "UPDATE media_requests SET status = 'rejected', rejection_reason = $1, \
                        admin_notes = $2, approved_by_id = $3, rejected_at = $4, updated_at = $5 \
                 WHERE id = $6",
            )
            .bind(&payload.rejection_reason)
            .bind(payload.admin_notes.as_deref())
            .bind(&acting)
            .bind(now)
            .bind(now)
            .bind(&payload.id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("reject request: {err}")))?
            .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!(
                "no media_request with id {}",
                payload.id
            )));
        }
        find_row(&payload.id).await
    }

    async fn find_row(id: &str) -> Result<RequestRow, ServerFnError> {
        let rows = list("all".to_owned()).await?;
        rows.into_iter()
            .find(|row| row.id == id)
            .ok_or_else(|| ServerFnError::new("request disappeared after update".to_owned()))
    }
}
