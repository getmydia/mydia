//! Import-list (Trakt / IMDb-list) management.
//!
//! Phoenix counterpart: `MydiaWeb.AdminImportListsLive`. An import
//! list is a periodic puller that ingests a remote list (Trakt
//! collection / IMDB list / TMDB list) into the local catalog.
//!
//! Validation:
//! - `name` non-blank.
//! - `kind` in `{trakt, imdb, tmdb}`.
//! - `url_or_id` non-blank.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ImportListRow {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub url_or_id: String,
    pub enabled: bool,
    pub last_synced_at: Option<String>,
    pub inserted_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct NewImportList {
    pub name: String,
    pub kind: String,
    pub url_or_id: String,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

const fn default_enabled() -> bool {
    true
}

pub const VALID_KINDS: &[&str] = &["trakt", "imdb", "tmdb"];

#[get("/api/admin/import_lists")]
pub async fn list_import_lists() -> Result<Vec<ImportListRow>, ServerFnError> {
    server::list().await
}

#[post("/api/admin/import_lists")]
pub async fn create_import_list(payload: NewImportList) -> Result<ImportListRow, ServerFnError> {
    server::create(payload).await
}

#[post("/api/admin/import_lists/delete")]
pub async fn delete_import_list(id: String) -> Result<(), ServerFnError> {
    server::delete(id).await
}

#[post("/api/admin/import_lists/toggle")]
pub async fn toggle_import_list(id: String) -> Result<ImportListRow, ServerFnError> {
    server::toggle(id).await
}

#[cfg(feature = "server")]
mod server {
    use super::{ImportListRow, NewImportList, VALID_KINDS};
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
        Option<chrono::DateTime<chrono::Utc>>,
    );

    pub(super) async fn list() -> Result<Vec<ImportListRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let rows: Vec<Row> = match &st.db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT id, name, kind, url_or_id, enabled, last_synced_at, inserted_at \
                 FROM import_lists ORDER BY inserted_at ASC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query import_lists: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT id, name, kind, url_or_id, enabled, last_synced_at, inserted_at \
                 FROM import_lists ORDER BY inserted_at ASC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query import_lists: {err}")))?,
        };
        Ok(rows
            .into_iter()
            .map(
                |(id, name, kind, url_or_id, enabled, last_synced_at, inserted_at)| ImportListRow {
                    id,
                    name,
                    kind,
                    url_or_id,
                    enabled,
                    last_synced_at: last_synced_at.map(|dt| dt.to_rfc3339()),
                    inserted_at: inserted_at.map(|dt| dt.to_rfc3339()),
                },
            )
            .collect())
    }

    pub(super) async fn create(payload: NewImportList) -> Result<ImportListRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        validate(&payload)?;
        let st = state().await?;
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now();
        match &st.db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "INSERT INTO import_lists (id, name, kind, url_or_id, enabled, inserted_at, updated_at) \
                     VALUES (?, ?, ?, ?, ?, ?, ?)",
                )
                .bind(&id)
                .bind(payload.name.trim())
                .bind(payload.kind.trim())
                .bind(payload.url_or_id.trim())
                .bind(payload.enabled)
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert import_list: {err}")))?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "INSERT INTO import_lists (id, name, kind, url_or_id, enabled, inserted_at, updated_at) \
                     VALUES ($1, $2, $3, $4, $5, $6, $7)",
                )
                .bind(&id)
                .bind(payload.name.trim())
                .bind(payload.kind.trim())
                .bind(payload.url_or_id.trim())
                .bind(payload.enabled)
                .bind(now)
                .bind(now)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert import_list: {err}")))?;
            }
        }
        Ok(ImportListRow {
            id,
            name: payload.name.trim().to_owned(),
            kind: payload.kind.trim().to_owned(),
            url_or_id: payload.url_or_id.trim().to_owned(),
            enabled: payload.enabled,
            last_synced_at: None,
            inserted_at: Some(now.to_rfc3339()),
        })
    }

    pub(super) async fn delete(id: String) -> Result<(), ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let affected = match &st.db {
            Db::Sqlite(pool) => sqlx::query("DELETE FROM import_lists WHERE id = ?")
                .bind(&id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("delete import_list: {err}")))?
                .rows_affected(),
            Db::Postgres(pool) => sqlx::query("DELETE FROM import_lists WHERE id = $1")
                .bind(&id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("delete import_list: {err}")))?
                .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!("no import_list with id {id}")));
        }
        Ok(())
    }

    pub(super) async fn toggle(id: String) -> Result<ImportListRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let now = chrono::Utc::now();
        let affected = match &st.db {
            Db::Sqlite(pool) => sqlx::query(
                "UPDATE import_lists SET enabled = NOT enabled, updated_at = ? WHERE id = ?",
            )
            .bind(now.to_rfc3339())
            .bind(&id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("toggle import_list: {err}")))?
            .rows_affected(),
            Db::Postgres(pool) => sqlx::query(
                "UPDATE import_lists SET enabled = NOT enabled, updated_at = $1 WHERE id = $2",
            )
            .bind(now)
            .bind(&id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("toggle import_list: {err}")))?
            .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!("no import_list with id {id}")));
        }
        list()
            .await?
            .into_iter()
            .find(|r| r.id == id)
            .ok_or_else(|| {
                ServerFnError::new("import_list disappeared between update and read".to_owned())
            })
    }

    fn validate(payload: &NewImportList) -> Result<(), ServerFnError> {
        if payload.name.trim().is_empty() {
            return Err(ServerFnError::new("Name is required".to_owned()));
        }
        if !VALID_KINDS.contains(&payload.kind.trim()) {
            return Err(ServerFnError::new(format!(
                "kind {:?} must be one of {VALID_KINDS:?}",
                payload.kind
            )));
        }
        if payload.url_or_id.trim().is_empty() {
            return Err(ServerFnError::new("URL or list id is required".to_owned()));
        }
        Ok(())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn validate_rejects_unknown_kind() {
            let result = validate(&NewImportList {
                name: "trending".into(),
                kind: "rss".into(),
                url_or_id: "https://example.com/list".into(),
                ..Default::default()
            });
            assert!(result.is_err());
        }

        #[test]
        fn validate_accepts_full_payload() {
            let result = validate(&NewImportList {
                name: "trending".into(),
                kind: "trakt".into(),
                url_or_id: "user/mylist".into(),
                ..Default::default()
            });
            assert!(result.is_ok());
        }
    }
}
