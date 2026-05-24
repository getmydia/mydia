//! User-side media request server functions.
//!
//! Phoenix counterpart: `MydiaWeb.RequestMediaLive.Index` +
//! `MydiaWeb.MyRequestsLive.Index` + `Mydia.MediaRequests`. The
//! admin-side approve/reject lives in `server_fns/admin/requests.rs`
//! (already shipped in U28); this module owns the read + create
//! surface from the requester's perspective.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Wire payload submitted by the request form. The session user owns
/// the request; we never accept a `requester_id` from the client.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateRequest {
    pub media_type: String,
    pub title: String,
    #[serde(default)]
    pub original_title: Option<String>,
    #[serde(default)]
    pub year: Option<i32>,
    #[serde(default)]
    pub tmdb_id: Option<i64>,
    #[serde(default)]
    pub tvdb_id: Option<i64>,
    #[serde(default)]
    pub imdb_id: Option<String>,
    #[serde(default)]
    pub requester_notes: Option<String>,
}

/// Wire-friendly view of a `media_requests` row, scoped to a single
/// requester. Matches the shape `MyRequestsLive.Index` renders —
/// title, year, status, optional rejection reason, timestamps.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MyRequest {
    pub id: String,
    pub media_type: String,
    pub title: String,
    pub year: Option<i32>,
    pub status: String,
    pub rejection_reason: Option<String>,
    pub requester_notes: Option<String>,
    pub admin_notes: Option<String>,
    pub inserted_at: Option<String>,
    pub approved_at: Option<String>,
    pub rejected_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateRequestAck {
    pub id: String,
}

#[get("/api/my-requests")]
pub async fn list_my_requests(filter: String) -> Result<Vec<MyRequest>, ServerFnError> {
    server::list_mine(filter).await
}

#[post("/api/requests")]
pub async fn create_request(payload: CreateRequest) -> Result<CreateRequestAck, ServerFnError> {
    server::create(payload).await
}

#[cfg(feature = "server")]
mod server {
    use super::{CreateRequest, CreateRequestAck, MyRequest};
    use crate::server_fns::auth::require_session_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_db::types::{DateTimeSecs, UuidText};
    use mydia_rs_db::{insert_active_model, DatabaseConnection};
    use mydia_rs_entities::media_requests;
    use sea_orm::entity::prelude::*;
    use sea_orm::query::QueryOrder;
    use sea_orm::sea_query::{Expr, ExprTrait};
    use sea_orm::Set;

    fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    fn parse_uuid(s: &str) -> Option<UuidText> {
        uuid::Uuid::parse_str(s).ok().map(UuidText::from)
    }

    pub(super) async fn list_mine(filter: String) -> Result<Vec<MyRequest>, ServerFnError> {
        let user_id = require_session_user_id().await?;
        let st = state()?;
        let Some(user_wrapper) = parse_uuid(&user_id) else {
            return Err(ServerFnError::new("invalid session user id"));
        };
        let backend = st.db.get_database_backend();
        let trimmed = filter.trim();
        let mut q = media_requests::Entity::find()
            .filter(
                Expr::col(media_requests::Column::RequesterId)
                    .eq(user_wrapper.into_simple_expr(backend)),
            )
            .order_by_desc(media_requests::Column::InsertedAt);
        if !(trimmed.is_empty() || trimmed == "all") {
            q = q.filter(media_requests::Column::Status.eq(trimmed.to_owned()));
        }
        let rows = q
            .all(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("list my requests: {err}")))?;
        Ok(rows
            .into_iter()
            .map(|r| MyRequest {
                id: r.id.to_string(),
                media_type: r.media_type,
                title: r.title,
                year: r.year,
                status: r.status,
                rejection_reason: r.rejection_reason,
                requester_notes: r.requester_notes,
                admin_notes: r.admin_notes,
                inserted_at: Some(r.inserted_at.0.to_rfc3339()),
                approved_at: r.approved_at.map(|dt| dt.0.to_rfc3339()),
                rejected_at: r.rejected_at.map(|dt| dt.0.to_rfc3339()),
            })
            .collect())
    }

    pub(super) async fn create(payload: CreateRequest) -> Result<CreateRequestAck, ServerFnError> {
        let user_id = require_session_user_id().await?;
        let st = state()?;

        if payload.title.trim().is_empty() {
            return Err(ServerFnError::new("Title is required"));
        }
        let media_type = match payload.media_type.as_str() {
            "movie" => "movie",
            "tv_show" => "tv_show",
            _ => return Err(ServerFnError::new("Invalid media type")),
        };

        let Some(user_wrapper) = parse_uuid(&user_id) else {
            return Err(ServerFnError::new("invalid session user id"));
        };

        // De-dup against an existing request from the same user for the
        // same TMDB id. Phoenix's `MediaRequests.create_request` returns
        // `{:error, :duplicate_request}` in this case.
        if let Some(tmdb_id) = payload.tmdb_id {
            if let Some(existing) =
                find_duplicate(&st.db, user_wrapper, tmdb_id, media_type).await?
            {
                return Ok(CreateRequestAck { id: existing });
            }
        }

        let id_uuid = uuid::Uuid::new_v4();
        let id_str = id_uuid.to_string();
        let id = UuidText::from(id_uuid);
        let now = DateTimeSecs::from(chrono::Utc::now());
        let tmdb_id_i32 = payload.tmdb_id.and_then(|n| i32::try_from(n).ok());
        let tvdb_id_i32 = payload.tvdb_id.and_then(|n| i32::try_from(n).ok());
        let am = media_requests::ActiveModel {
            id: Set(id),
            media_type: Set(media_type.to_owned()),
            title: Set(payload.title.trim().to_owned()),
            original_title: Set(payload.original_title.clone()),
            year: Set(payload.year),
            tmdb_id: Set(tmdb_id_i32),
            imdb_id: Set(payload.imdb_id.clone()),
            status: Set("pending".to_owned()),
            requester_notes: Set(payload.requester_notes.clone()),
            admin_notes: Set(None),
            rejection_reason: Set(None),
            approved_at: Set(None),
            rejected_at: Set(None),
            requester_id: Set(user_wrapper),
            approved_by_id: Set(None),
            media_item_id: Set(None),
            inserted_at: Set(now),
            updated_at: Set(now),
            tvdb_id: Set(tvdb_id_i32),
        };
        insert_active_model(am, &st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("create request: {err}")))?;

        Ok(CreateRequestAck { id: id_str })
    }

    async fn find_duplicate(
        db: &DatabaseConnection,
        user_wrapper: UuidText,
        tmdb_id: i64,
        media_type: &str,
    ) -> Result<Option<String>, ServerFnError> {
        let backend = db.get_database_backend();
        let tmdb_id_i32 = i32::try_from(tmdb_id).ok();
        let mut q = media_requests::Entity::find()
            .filter(
                Expr::col(media_requests::Column::RequesterId)
                    .eq(user_wrapper.into_simple_expr(backend)),
            )
            .filter(media_requests::Column::MediaType.eq(media_type.to_owned()))
            .filter(media_requests::Column::Status.ne("rejected".to_owned()));
        if let Some(id) = tmdb_id_i32 {
            q = q.filter(media_requests::Column::TmdbId.eq(id));
        } else {
            return Ok(None);
        }
        let row = q
            .one(db)
            .await
            .map_err(|err| ServerFnError::new(format!("dup lookup: {err}")))?;
        Ok(row.map(|r| r.id.to_string()))
    }
}
