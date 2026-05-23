//! Release-blacklist management.
//!
//! Phoenix counterpart: `MydiaWeb.AdminReleaseBlacklistLive`. The
//! blacklist holds release titles / hashes mydia refuses to grab
//! when the download pipeline matches them.
//!
//! Validation:
//! - `pattern` non-blank.
//! - `kind` in `{title, hash}`.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BlacklistEntryRow {
    pub id: String,
    pub kind: String,
    pub pattern: String,
    #[serde(default)]
    pub reason: Option<String>,
    pub inserted_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct NewBlacklistEntry {
    pub kind: String,
    pub pattern: String,
    #[serde(default)]
    pub reason: Option<String>,
}

pub const VALID_KINDS: &[&str] = &["title", "hash"];

#[get("/api/admin/release_blacklist")]
pub async fn list_blacklist_entries() -> Result<Vec<BlacklistEntryRow>, ServerFnError> {
    server::list().await
}

#[post("/api/admin/release_blacklist")]
pub async fn create_blacklist_entry(
    payload: NewBlacklistEntry,
) -> Result<BlacklistEntryRow, ServerFnError> {
    server::create(payload).await
}

#[post("/api/admin/release_blacklist/delete")]
pub async fn delete_blacklist_entry(id: String) -> Result<(), ServerFnError> {
    server::delete(id).await
}

#[cfg(feature = "server")]
mod server {
    use super::{BlacklistEntryRow, NewBlacklistEntry, VALID_KINDS};
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
        Option<String>,
        Option<chrono::DateTime<chrono::Utc>>,
    );

    pub(super) async fn list() -> Result<Vec<BlacklistEntryRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let rows: Vec<Row> = match &st.db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT id, kind, pattern, reason, inserted_at \
                 FROM release_blacklist ORDER BY inserted_at DESC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query release_blacklist: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT id, kind, pattern, reason, inserted_at \
                 FROM release_blacklist ORDER BY inserted_at DESC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query release_blacklist: {err}")))?,
        };
        Ok(rows
            .into_iter()
            .map(
                |(id, kind, pattern, reason, inserted_at)| BlacklistEntryRow {
                    id,
                    kind,
                    pattern,
                    reason,
                    inserted_at: inserted_at.map(|dt| dt.to_rfc3339()),
                },
            )
            .collect())
    }

    pub(super) async fn create(
        payload: NewBlacklistEntry,
    ) -> Result<BlacklistEntryRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        validate(&payload)?;
        let st = state().await?;
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now();
        match &st.db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "INSERT INTO release_blacklist (id, kind, pattern, reason, inserted_at, updated_at) \
                     VALUES (?, ?, ?, ?, ?, ?)",
                )
                .bind(&id)
                .bind(payload.kind.trim())
                .bind(payload.pattern.trim())
                .bind(payload.reason.as_deref())
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert blacklist: {err}")))?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "INSERT INTO release_blacklist (id, kind, pattern, reason, inserted_at, updated_at) \
                     VALUES ($1, $2, $3, $4, $5, $6)",
                )
                .bind(&id)
                .bind(payload.kind.trim())
                .bind(payload.pattern.trim())
                .bind(payload.reason.as_deref())
                .bind(now)
                .bind(now)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert blacklist: {err}")))?;
            }
        }
        Ok(BlacklistEntryRow {
            id,
            kind: payload.kind.trim().to_owned(),
            pattern: payload.pattern.trim().to_owned(),
            reason: payload.reason.clone(),
            inserted_at: Some(now.to_rfc3339()),
        })
    }

    pub(super) async fn delete(id: String) -> Result<(), ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let affected = match &st.db {
            Db::Sqlite(pool) => sqlx::query("DELETE FROM release_blacklist WHERE id = ?")
                .bind(&id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("delete blacklist: {err}")))?
                .rows_affected(),
            Db::Postgres(pool) => sqlx::query("DELETE FROM release_blacklist WHERE id = $1")
                .bind(&id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("delete blacklist: {err}")))?
                .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!(
                "no blacklist entry with id {id}"
            )));
        }
        Ok(())
    }

    fn validate(payload: &NewBlacklistEntry) -> Result<(), ServerFnError> {
        if !VALID_KINDS.contains(&payload.kind.trim()) {
            return Err(ServerFnError::new(format!(
                "kind {:?} must be one of {VALID_KINDS:?}",
                payload.kind
            )));
        }
        if payload.pattern.trim().is_empty() {
            return Err(ServerFnError::new("Pattern is required".to_owned()));
        }
        Ok(())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn validate_accepts_title_pattern() {
            let result = validate(&NewBlacklistEntry {
                kind: "title".into(),
                pattern: "*.CAM.*".into(),
                ..Default::default()
            });
            assert!(result.is_ok());
        }

        #[test]
        fn validate_rejects_empty_pattern() {
            let result = validate(&NewBlacklistEntry {
                kind: "title".into(),
                pattern: "   ".into(),
                ..Default::default()
            });
            assert!(result.is_err());
        }
    }
}
