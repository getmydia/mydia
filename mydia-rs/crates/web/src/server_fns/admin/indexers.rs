//! Indexer-management server functions.
//!
//! Phoenix counterpart: `MydiaWeb.AdminIndexersLive`. Each indexer
//! row drives the Cardigann engine port — name, definition slug
//! (the cardigann YAML this indexer was bootstrapped from), base
//! URL, optional API key, enabled flag.
//!
//! Validation:
//! - `name` non-blank.
//! - `definition` non-blank (the cardigann definition name).
//! - `base_url` parses as URL.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct IndexerRow {
    pub id: String,
    pub name: String,
    pub definition: String,
    pub base_url: String,
    pub enabled: bool,
    pub inserted_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct NewIndexer {
    pub name: String,
    pub definition: String,
    pub base_url: String,
    #[serde(default)]
    pub api_key: Option<String>,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

const fn default_enabled() -> bool {
    true
}

#[get("/api/admin/indexers")]
pub async fn list_indexers() -> Result<Vec<IndexerRow>, ServerFnError> {
    server::list().await
}

#[post("/api/admin/indexers")]
pub async fn create_indexer(payload: NewIndexer) -> Result<IndexerRow, ServerFnError> {
    server::create(payload).await
}

#[post("/api/admin/indexers/delete")]
pub async fn delete_indexer(id: String) -> Result<(), ServerFnError> {
    server::delete(id).await
}

#[post("/api/admin/indexers/toggle")]
pub async fn toggle_indexer(id: String) -> Result<IndexerRow, ServerFnError> {
    server::toggle(id).await
}

#[cfg(feature = "server")]
mod server {
    use super::{IndexerRow, NewIndexer};
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

    pub(super) async fn list() -> Result<Vec<IndexerRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let rows: Vec<Row> = match &st.db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT id, name, definition, base_url, enabled, inserted_at \
                 FROM indexers ORDER BY inserted_at ASC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query indexers: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT id, name, definition, base_url, enabled, inserted_at \
                 FROM indexers ORDER BY inserted_at ASC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query indexers: {err}")))?,
        };
        Ok(rows
            .into_iter()
            .map(
                |(id, name, definition, base_url, enabled, inserted_at)| IndexerRow {
                    id,
                    name,
                    definition,
                    base_url,
                    enabled,
                    inserted_at: inserted_at.map(|dt| dt.to_rfc3339()),
                },
            )
            .collect())
    }

    pub(super) async fn create(payload: NewIndexer) -> Result<IndexerRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        validate(&payload)?;
        let st = state().await?;

        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now();
        match &st.db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "INSERT INTO indexers (id, name, definition, base_url, api_key, enabled, inserted_at, updated_at) \
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                )
                .bind(&id)
                .bind(payload.name.trim())
                .bind(payload.definition.trim())
                .bind(payload.base_url.trim())
                .bind(payload.api_key.as_deref())
                .bind(payload.enabled)
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert indexer: {err}")))?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "INSERT INTO indexers (id, name, definition, base_url, api_key, enabled, inserted_at, updated_at) \
                     VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
                )
                .bind(&id)
                .bind(payload.name.trim())
                .bind(payload.definition.trim())
                .bind(payload.base_url.trim())
                .bind(payload.api_key.as_deref())
                .bind(payload.enabled)
                .bind(now)
                .bind(now)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert indexer: {err}")))?;
            }
        }
        Ok(IndexerRow {
            id,
            name: payload.name.trim().to_owned(),
            definition: payload.definition.trim().to_owned(),
            base_url: payload.base_url.trim().to_owned(),
            enabled: payload.enabled,
            inserted_at: Some(now.to_rfc3339()),
        })
    }

    pub(super) async fn delete(id: String) -> Result<(), ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let affected = match &st.db {
            Db::Sqlite(pool) => sqlx::query("DELETE FROM indexers WHERE id = ?")
                .bind(&id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("delete indexer: {err}")))?
                .rows_affected(),
            Db::Postgres(pool) => sqlx::query("DELETE FROM indexers WHERE id = $1")
                .bind(&id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("delete indexer: {err}")))?
                .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!("no indexer with id {id}")));
        }
        Ok(())
    }

    pub(super) async fn toggle(id: String) -> Result<IndexerRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let now = chrono::Utc::now();
        let affected = match &st.db {
            Db::Sqlite(pool) => sqlx::query(
                "UPDATE indexers SET enabled = NOT enabled, updated_at = ? WHERE id = ?",
            )
            .bind(now.to_rfc3339())
            .bind(&id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("toggle indexer: {err}")))?
            .rows_affected(),
            Db::Postgres(pool) => sqlx::query(
                "UPDATE indexers SET enabled = NOT enabled, updated_at = $1 WHERE id = $2",
            )
            .bind(now)
            .bind(&id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("toggle indexer: {err}")))?
            .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!("no indexer with id {id}")));
        }
        list()
            .await?
            .into_iter()
            .find(|r| r.id == id)
            .ok_or_else(|| {
                ServerFnError::new("indexer disappeared between update and read".to_owned())
            })
    }

    fn validate(payload: &NewIndexer) -> Result<(), ServerFnError> {
        if payload.name.trim().is_empty() {
            return Err(ServerFnError::new("Name is required".to_owned()));
        }
        if payload.definition.trim().is_empty() {
            return Err(ServerFnError::new(
                "Cardigann definition is required".to_owned(),
            ));
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
        fn validate_rejects_bad_url() {
            let result = validate(&NewIndexer {
                name: "ix".into(),
                definition: "iptorrents".into(),
                base_url: "not a url".into(),
                ..Default::default()
            });
            assert!(result.is_err());
        }

        #[test]
        fn validate_accepts_full_payload() {
            let result = validate(&NewIndexer {
                name: "ix".into(),
                definition: "iptorrents".into(),
                base_url: "https://iptorrents.com".into(),
                ..Default::default()
            });
            assert!(result.is_ok());
        }
    }
}
