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
    use mydia_rs_db::types::{DateTimeSecs, UuidText};
    use mydia_rs_entities::{media_requests, users};
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

    pub(super) async fn list(status: String) -> Result<Vec<RequestRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let state = state().await?;

        // `status=""` or `status="all"` mean "no filter"; any other
        // value binds into the WHERE clause.
        let trimmed = status.trim();
        let mut q = media_requests::Entity::find()
            .order_by_desc(media_requests::Column::InsertedAt);
        if !(trimmed.is_empty() || trimmed == "all") {
            q = q.filter(media_requests::Column::Status.eq(trimmed.to_owned()));
        }
        let rows = q
            .all(&state.db)
            .await
            .map_err(|err| ServerFnError::new(format!("query media_requests: {err}")))?;

        // Pull requester usernames in one round-trip.
        let user_ids: Vec<UuidText> = rows.iter().map(|r| r.requester_id).collect();
        let user_rows = users::Entity::find()
            .filter(users::Column::Id.is_in(user_ids))
            .all(&state.db)
            .await
            .map_err(|err| ServerFnError::new(format!("query users: {err}")))?;
        let user_map: std::collections::HashMap<UuidText, Option<String>> = user_rows
            .into_iter()
            .map(|u| (u.id, u.username))
            .collect();

        Ok(rows
            .into_iter()
            .map(|r| RequestRow {
                id: r.id.to_string(),
                media_type: r.media_type,
                title: r.title,
                year: r.year,
                status: r.status,
                requester_label: user_map.get(&r.requester_id).cloned().flatten(),
                requester_notes: r.requester_notes,
                admin_notes: r.admin_notes,
                rejection_reason: r.rejection_reason,
                inserted_at: Some(r.inserted_at.0.to_rfc3339()),
            })
            .collect())
    }

    pub(super) async fn approve(payload: ApproveRequest) -> Result<RequestRow, ServerFnError> {
        let acting = require_admin_user_id().await?;
        let state = state().await?;
        let now = DateTimeSecs::from(chrono::Utc::now());
        let Some(wrapper) = parse_uuid(&payload.id) else {
            return Err(ServerFnError::new(format!(
                "invalid media_request id {}",
                payload.id
            )));
        };
        let Some(acting_uuid) = parse_uuid(&acting) else {
            return Err(ServerFnError::new(format!(
                "invalid acting user id {acting}"
            )));
        };
        let backend = state.db.get_database_backend();
        let res = media_requests::Entity::update_many()
            .col_expr(
                media_requests::Column::Status,
                Expr::value("approved".to_owned()),
            )
            .col_expr(
                media_requests::Column::AdminNotes,
                Expr::value(payload.admin_notes.clone()),
            )
            .col_expr(
                media_requests::Column::ApprovedById,
                acting_uuid.into_simple_expr(backend),
            )
            .col_expr(
                media_requests::Column::ApprovedAt,
                now.into_simple_expr(backend),
            )
            .col_expr(
                media_requests::Column::UpdatedAt,
                now.into_simple_expr(backend),
            )
            .filter(Expr::col(media_requests::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(&state.db)
            .await
            .map_err(|err| ServerFnError::new(format!("approve request: {err}")))?;
        if res.rows_affected == 0 {
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
        let now = DateTimeSecs::from(chrono::Utc::now());
        let Some(wrapper) = parse_uuid(&payload.id) else {
            return Err(ServerFnError::new(format!(
                "invalid media_request id {}",
                payload.id
            )));
        };
        let Some(acting_uuid) = parse_uuid(&acting) else {
            return Err(ServerFnError::new(format!(
                "invalid acting user id {acting}"
            )));
        };
        let backend = state.db.get_database_backend();
        let res = media_requests::Entity::update_many()
            .col_expr(
                media_requests::Column::Status,
                Expr::value("rejected".to_owned()),
            )
            .col_expr(
                media_requests::Column::RejectionReason,
                Expr::value(payload.rejection_reason.clone()),
            )
            .col_expr(
                media_requests::Column::AdminNotes,
                Expr::value(payload.admin_notes.clone()),
            )
            .col_expr(
                media_requests::Column::ApprovedById,
                acting_uuid.into_simple_expr(backend),
            )
            .col_expr(
                media_requests::Column::RejectedAt,
                now.into_simple_expr(backend),
            )
            .col_expr(
                media_requests::Column::UpdatedAt,
                now.into_simple_expr(backend),
            )
            .filter(Expr::col(media_requests::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(&state.db)
            .await
            .map_err(|err| ServerFnError::new(format!("reject request: {err}")))?;
        if res.rows_affected == 0 {
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
