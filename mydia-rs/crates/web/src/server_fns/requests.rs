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
    use mydia_rs_db::Db;

    fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    pub(super) async fn list_mine(filter: String) -> Result<Vec<MyRequest>, ServerFnError> {
        let user_id = require_session_user_id().await?;
        let st = state()?;
        let trimmed = filter.trim();
        let status_filter = if trimmed.is_empty() || trimmed == "all" {
            None
        } else {
            Some(trimmed)
        };

        type Row = (
            String,
            String,
            String,
            Option<i32>,
            String,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<chrono::DateTime<chrono::Utc>>,
            Option<chrono::DateTime<chrono::Utc>>,
            Option<chrono::DateTime<chrono::Utc>>,
        );

        const SELECT_COLS: &str =
            "id, media_type, title, year, status, rejection_reason, requester_notes, \
             admin_notes, inserted_at, approved_at, rejected_at";

        let rows: Vec<Row> = match (&st.db, status_filter) {
            (Db::Sqlite(pool), None) => sqlx::query_as(&format!(
                "SELECT {SELECT_COLS} FROM media_requests WHERE requester_id = ? \
                 ORDER BY inserted_at DESC"
            ))
            .bind(&user_id)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("list my requests: {err}")))?,
            (Db::Sqlite(pool), Some(filter)) => sqlx::query_as(&format!(
                "SELECT {SELECT_COLS} FROM media_requests \
                 WHERE requester_id = ? AND status = ? \
                 ORDER BY inserted_at DESC"
            ))
            .bind(&user_id)
            .bind(filter)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("list my requests: {err}")))?,
            (Db::Postgres(pool), None) => sqlx::query_as(&format!(
                "SELECT {SELECT_COLS} FROM media_requests WHERE requester_id = $1 \
                 ORDER BY inserted_at DESC"
            ))
            .bind(&user_id)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("list my requests: {err}")))?,
            (Db::Postgres(pool), Some(filter)) => sqlx::query_as(&format!(
                "SELECT {SELECT_COLS} FROM media_requests \
                 WHERE requester_id = $1 AND status = $2 \
                 ORDER BY inserted_at DESC"
            ))
            .bind(&user_id)
            .bind(filter)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("list my requests: {err}")))?,
        };

        Ok(rows
            .into_iter()
            .map(|r| MyRequest {
                id: r.0,
                media_type: r.1,
                title: r.2,
                year: r.3,
                status: r.4,
                rejection_reason: r.5,
                requester_notes: r.6,
                admin_notes: r.7,
                inserted_at: r.8.map(|dt| dt.to_rfc3339()),
                approved_at: r.9.map(|dt| dt.to_rfc3339()),
                rejected_at: r.10.map(|dt| dt.to_rfc3339()),
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

        // De-dup against an existing request from the same user for the
        // same TMDB id. Phoenix's `MediaRequests.create_request` returns
        // `{:error, :duplicate_request}` in this case.
        if let Some(tmdb_id) = payload.tmdb_id {
            if let Some(existing) = find_duplicate(&st.db, &user_id, tmdb_id, media_type).await? {
                return Ok(CreateRequestAck { id: existing });
            }
        }

        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now();

        match &st.db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "INSERT INTO media_requests \
                       (id, media_type, title, original_title, year, tmdb_id, imdb_id, \
                        status, requester_notes, requester_id, inserted_at, updated_at) \
                     VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?)",
                )
                .bind(&id)
                .bind(media_type)
                .bind(payload.title.trim())
                .bind(payload.original_title.as_deref())
                .bind(payload.year)
                .bind(payload.tmdb_id)
                .bind(payload.imdb_id.as_deref())
                .bind(payload.requester_notes.as_deref())
                .bind(&user_id)
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("create request: {err}")))?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "INSERT INTO media_requests \
                       (id, media_type, title, original_title, year, tmdb_id, imdb_id, \
                        status, requester_notes, requester_id, inserted_at, updated_at) \
                     VALUES ($1, $2, $3, $4, $5, $6, $7, 'pending', $8, $9, $10, $11)",
                )
                .bind(&id)
                .bind(media_type)
                .bind(payload.title.trim())
                .bind(payload.original_title.as_deref())
                .bind(payload.year)
                .bind(payload.tmdb_id)
                .bind(payload.imdb_id.as_deref())
                .bind(payload.requester_notes.as_deref())
                .bind(&user_id)
                .bind(now)
                .bind(now)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("create request: {err}")))?;
            }
        }

        Ok(CreateRequestAck { id })
    }

    async fn find_duplicate(
        db: &Db,
        user_id: &str,
        tmdb_id: i64,
        media_type: &str,
    ) -> Result<Option<String>, ServerFnError> {
        let row: Option<(String,)> = match db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT id FROM media_requests \
                 WHERE requester_id = ? AND tmdb_id = ? AND media_type = ? AND status != 'rejected' \
                 LIMIT 1",
            )
            .bind(user_id)
            .bind(tmdb_id)
            .bind(media_type)
            .fetch_optional(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("dup lookup: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT id FROM media_requests \
                 WHERE requester_id = $1 AND tmdb_id = $2 AND media_type = $3 AND status != 'rejected' \
                 LIMIT 1",
            )
            .bind(user_id)
            .bind(tmdb_id)
            .bind(media_type)
            .fetch_optional(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("dup lookup: {err}")))?,
        };
        Ok(row.map(|(id,)| id))
    }
}
