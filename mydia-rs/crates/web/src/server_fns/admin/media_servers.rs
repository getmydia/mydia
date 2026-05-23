//! Media-server (Plex / Jellyfin / Emby) adapter management.
//!
//! Phoenix counterpart: `MydiaWeb.AdminMediaServersLive`. Each row
//! is one external media-server adapter we read library data from
//! and (optionally) write watched state back to.
//!
//! Validation:
//! - `name` non-blank.
//! - `kind` in the small `{plex, jellyfin, emby}` set.
//! - `base_url` parses as URL.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MediaServerRow {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub base_url: String,
    pub enabled: bool,
    pub inserted_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct NewMediaServer {
    pub name: String,
    pub kind: String,
    pub base_url: String,
    #[serde(default)]
    pub access_token: Option<String>,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

const fn default_enabled() -> bool {
    true
}

pub const VALID_KINDS: &[&str] = &["plex", "jellyfin", "emby"];

#[get("/api/admin/media_servers")]
pub async fn list_media_servers() -> Result<Vec<MediaServerRow>, ServerFnError> {
    server::list().await
}

#[post("/api/admin/media_servers")]
pub async fn create_media_server(payload: NewMediaServer) -> Result<MediaServerRow, ServerFnError> {
    server::create(payload).await
}

#[post("/api/admin/media_servers/delete")]
pub async fn delete_media_server(id: String) -> Result<(), ServerFnError> {
    server::delete(id).await
}

#[post("/api/admin/media_servers/toggle")]
pub async fn toggle_media_server(id: String) -> Result<MediaServerRow, ServerFnError> {
    server::toggle(id).await
}

#[cfg(feature = "server")]
mod server {
    use super::{MediaServerRow, NewMediaServer, VALID_KINDS};
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

    type Row = (
        String,
        String,
        String,
        String,
        bool,
        Option<chrono::DateTime<chrono::Utc>>,
    );

    pub(super) async fn list() -> Result<Vec<MediaServerRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let rows: Vec<Row> = match &st.db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT id, name, kind, base_url, enabled, inserted_at \
                 FROM media_servers ORDER BY inserted_at ASC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query media_servers: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT id, name, kind, base_url, enabled, inserted_at \
                 FROM media_servers ORDER BY inserted_at ASC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query media_servers: {err}")))?,
        };
        Ok(rows
            .into_iter()
            .map(
                |(id, name, kind, base_url, enabled, inserted_at)| MediaServerRow {
                    id,
                    name,
                    kind,
                    base_url,
                    enabled,
                    inserted_at: inserted_at.map(|dt| dt.to_rfc3339()),
                },
            )
            .collect())
    }

    pub(super) async fn create(payload: NewMediaServer) -> Result<MediaServerRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        validate(&payload)?;
        let st = state().await?;
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now();
        match &st.db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "INSERT INTO media_servers (id, name, kind, base_url, access_token, enabled, inserted_at, updated_at) \
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                )
                .bind(&id)
                .bind(payload.name.trim())
                .bind(payload.kind.trim())
                .bind(payload.base_url.trim())
                .bind(payload.access_token.as_deref())
                .bind(payload.enabled)
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert media_server: {err}")))?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "INSERT INTO media_servers (id, name, kind, base_url, access_token, enabled, inserted_at, updated_at) \
                     VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
                )
                .bind(&id)
                .bind(payload.name.trim())
                .bind(payload.kind.trim())
                .bind(payload.base_url.trim())
                .bind(payload.access_token.as_deref())
                .bind(payload.enabled)
                .bind(now)
                .bind(now)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert media_server: {err}")))?;
            }
        }
        Ok(MediaServerRow {
            id,
            name: payload.name.trim().to_owned(),
            kind: payload.kind.trim().to_owned(),
            base_url: payload.base_url.trim().to_owned(),
            enabled: payload.enabled,
            inserted_at: Some(now.to_rfc3339()),
        })
    }

    pub(super) async fn delete(id: String) -> Result<(), ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let affected = match &st.db {
            Db::Sqlite(pool) => sqlx::query("DELETE FROM media_servers WHERE id = ?")
                .bind(&id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("delete media_server: {err}")))?
                .rows_affected(),
            Db::Postgres(pool) => sqlx::query("DELETE FROM media_servers WHERE id = $1")
                .bind(&id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("delete media_server: {err}")))?
                .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!("no media_server with id {id}")));
        }
        Ok(())
    }

    pub(super) async fn toggle(id: String) -> Result<MediaServerRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let now = chrono::Utc::now();
        let affected = match &st.db {
            Db::Sqlite(pool) => sqlx::query(
                "UPDATE media_servers SET enabled = NOT enabled, updated_at = ? WHERE id = ?",
            )
            .bind(now.to_rfc3339())
            .bind(&id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("toggle media_server: {err}")))?
            .rows_affected(),
            Db::Postgres(pool) => sqlx::query(
                "UPDATE media_servers SET enabled = NOT enabled, updated_at = $1 WHERE id = $2",
            )
            .bind(now)
            .bind(&id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("toggle media_server: {err}")))?
            .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!("no media_server with id {id}")));
        }
        list()
            .await?
            .into_iter()
            .find(|r| r.id == id)
            .ok_or_else(|| {
                ServerFnError::new("media_server disappeared between update and read".to_owned())
            })
    }

    fn validate(payload: &NewMediaServer) -> Result<(), ServerFnError> {
        if payload.name.trim().is_empty() {
            return Err(ServerFnError::new("Name is required".to_owned()));
        }
        if !VALID_KINDS.contains(&payload.kind.trim()) {
            return Err(ServerFnError::new(format!(
                "kind {:?} must be one of {VALID_KINDS:?}",
                payload.kind
            )));
        }
        if reqwest::Url::parse(payload.base_url.trim()).is_err() {
            return Err(ServerFnError::new(format!(
                "base_url {:?} is not a valid URL",
                payload.base_url
            )));
        }
        Ok(())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn validate_rejects_unknown_kind() {
            let result = validate(&NewMediaServer {
                name: "x".into(),
                kind: "kodi".into(),
                base_url: "http://localhost".into(),
                ..Default::default()
            });
            assert!(result.is_err());
        }

        #[test]
        fn validate_accepts_known_kind() {
            let result = validate(&NewMediaServer {
                name: "x".into(),
                kind: "jellyfin".into(),
                base_url: "http://localhost:8096".into(),
                ..Default::default()
            });
            assert!(result.is_ok());
        }
    }
}
