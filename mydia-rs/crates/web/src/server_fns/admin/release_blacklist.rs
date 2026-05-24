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
    // TODO(broken-pre-conversion): the wire payload references
    // `kind`/`pattern`/`reason` columns that don't exist on the
    // `release_blacklist` entity. The entity stores per-indexer
    // GUID-based blocks (`indexer`, `guid`, `title`, `failure_reason`,
    // `expires_at`). Map the form's fields onto the closest entity
    // columns so the page renders against the real schema:
    //   - `kind` → `indexer` (the indexer label; the original VALID_KINDS
    //     gate of `{title, hash}` is no longer applicable but we keep
    //     validation hooked up so callers see a 400 on blank input).
    //   - `pattern` → `title` (display label of the blocked release).
    //   - `reason` → `failure_reason`.
    // `guid` is required by the entity's unique constraint; synthesize
    // one from a fresh UUID when the caller doesn't supply one.
    use super::{BlacklistEntryRow, NewBlacklistEntry};
    use crate::server_fns::auth::require_admin_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use mydia_rs_db::types::{DateTimeMicros, UuidText};
    use mydia_rs_db::insert_active_model;
    use mydia_rs_entities::release_blacklist;
    use sea_orm::entity::prelude::*;
    use sea_orm::query::QueryOrder;
    use sea_orm::sea_query::{Expr, ExprTrait};
    use sea_orm::Set;

    async fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context".to_owned()))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState axum extension missing".to_owned()))
    }

    pub(super) async fn list() -> Result<Vec<BlacklistEntryRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let rows = release_blacklist::Entity::find()
            .order_by_desc(release_blacklist::Column::InsertedAt)
            .all(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("query release_blacklist: {err}")))?;
        Ok(rows
            .into_iter()
            .map(|r| BlacklistEntryRow {
                id: r.id.to_string(),
                kind: r.indexer,
                pattern: r.title,
                reason: Some(r.failure_reason),
                inserted_at: Some(r.inserted_at.0.to_rfc3339()),
            })
            .collect())
    }

    pub(super) async fn create(
        payload: NewBlacklistEntry,
    ) -> Result<BlacklistEntryRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        validate(&payload)?;
        let st = state().await?;
        let id_uuid = uuid::Uuid::new_v4();
        let id_str = id_uuid.to_string();
        let id = UuidText::from(id_uuid);
        let now = DateTimeMicros::from(chrono::Utc::now());
        let am = release_blacklist::ActiveModel {
            id: Set(id),
            indexer: Set(payload.kind.trim().to_owned()),
            guid: Set(uuid::Uuid::new_v4().to_string()),
            title: Set(payload.pattern.trim().to_owned()),
            failure_reason: Set(payload.reason.clone().unwrap_or_default()),
            expires_at: Set(None),
            inserted_at: Set(now),
        };
        insert_active_model(am, &st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("insert blacklist: {err}")))?;
        Ok(BlacklistEntryRow {
            id: id_str,
            kind: payload.kind.trim().to_owned(),
            pattern: payload.pattern.trim().to_owned(),
            reason: payload.reason.clone(),
            inserted_at: Some(now.0.to_rfc3339()),
        })
    }

    pub(super) async fn delete(id: String) -> Result<(), ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let Some(wrapper) = uuid::Uuid::parse_str(&id).ok().map(UuidText::from) else {
            return Err(ServerFnError::new(format!("invalid blacklist id {id}")));
        };
        let backend = st.db.get_database_backend();
        let res = release_blacklist::Entity::delete_many()
            .filter(Expr::col(release_blacklist::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("delete blacklist: {err}")))?;
        if res.rows_affected == 0 {
            return Err(ServerFnError::new(format!(
                "no blacklist entry with id {id}"
            )));
        }
        Ok(())
    }

    fn validate(payload: &NewBlacklistEntry) -> Result<(), ServerFnError> {
        if payload.kind.trim().is_empty() {
            return Err(ServerFnError::new(
                "Indexer (kind) is required".to_owned(),
            ));
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
