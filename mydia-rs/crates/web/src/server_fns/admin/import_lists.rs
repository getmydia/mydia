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
    // TODO(broken-pre-conversion): the page's wire payload uses
    // `kind`/`url_or_id` fields. The entity stores `r#type`/`media_type`
    // and a JSON `config` blob. Map `kind` → `r#type`, store
    // `url_or_id` inside `config` as a `url_or_id` JSON field, and
    // default `media_type` to `"movie"` since the page doesn't expose
    // it yet.
    use super::{ImportListRow, NewImportList};
    use crate::server_fns::auth::require_admin_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use mydia_rs_db::types::{DateTimeSecs, JsonMap, UuidText};
    use mydia_rs_db::insert_active_model;
    use mydia_rs_entities::import_lists;
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

    fn parse_uuid(s: &str) -> Option<UuidText> {
        uuid::Uuid::parse_str(s).ok().map(UuidText::from)
    }

    fn extract_url_or_id(cfg: Option<&JsonMap<serde_json::Value>>) -> String {
        cfg.and_then(|c| c.0.get("url_or_id"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .to_owned()
    }

    fn model_to_row(m: &import_lists::Model) -> ImportListRow {
        ImportListRow {
            id: m.id.to_string(),
            name: m.name.clone(),
            kind: m.r#type.clone(),
            url_or_id: extract_url_or_id(m.config.as_ref()),
            enabled: m.enabled,
            last_synced_at: m.last_synced_at.map(|dt| dt.0.to_rfc3339()),
            inserted_at: Some(m.inserted_at.0.to_rfc3339()),
        }
    }

    pub(super) async fn list() -> Result<Vec<ImportListRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let rows = import_lists::Entity::find()
            .order_by_asc(import_lists::Column::InsertedAt)
            .all(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("query import_lists: {err}")))?;
        Ok(rows.iter().map(model_to_row).collect())
    }

    pub(super) async fn create(payload: NewImportList) -> Result<ImportListRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        validate(&payload)?;
        let st = state().await?;
        let id_uuid = uuid::Uuid::new_v4();
        let id_str = id_uuid.to_string();
        let id = UuidText::from(id_uuid);
        let now = DateTimeSecs::from(chrono::Utc::now());
        let cfg = JsonMap(serde_json::json!({
            "url_or_id": payload.url_or_id.trim(),
        }));
        let am = import_lists::ActiveModel {
            id: Set(id),
            name: Set(payload.name.trim().to_owned()),
            r#type: Set(payload.kind.trim().to_owned()),
            media_type: Set("movie".to_owned()),
            enabled: Set(payload.enabled),
            sync_interval: Set(86_400),
            auto_add: Set(false),
            monitored: Set(true),
            config: Set(Some(cfg)),
            last_synced_at: Set(None),
            sync_error: Set(None),
            quality_profile_id: Set(None),
            library_path_id: Set(None),
            inserted_at: Set(now),
            updated_at: Set(now),
            target_collection_id: Set(None),
        };
        insert_active_model(am, &st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("insert import_list: {err}")))?;
        Ok(ImportListRow {
            id: id_str,
            name: payload.name.trim().to_owned(),
            kind: payload.kind.trim().to_owned(),
            url_or_id: payload.url_or_id.trim().to_owned(),
            enabled: payload.enabled,
            last_synced_at: None,
            inserted_at: Some(now.0.to_rfc3339()),
        })
    }

    pub(super) async fn delete(id: String) -> Result<(), ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let Some(wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new(format!("invalid import_list id {id}")));
        };
        let backend = st.db.get_database_backend();
        let res = import_lists::Entity::delete_many()
            .filter(Expr::col(import_lists::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("delete import_list: {err}")))?;
        if res.rows_affected == 0 {
            return Err(ServerFnError::new(format!("no import_list with id {id}")));
        }
        Ok(())
    }

    pub(super) async fn toggle(id: String) -> Result<ImportListRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let Some(wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new(format!("invalid import_list id {id}")));
        };
        let backend = st.db.get_database_backend();
        let Some(row) = import_lists::Entity::find()
            .filter(Expr::col(import_lists::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .one(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("read import_list: {err}")))?
        else {
            return Err(ServerFnError::new(format!("no import_list with id {id}")));
        };
        let now = DateTimeSecs::from(chrono::Utc::now());
        let new_enabled = !row.enabled;
        import_lists::Entity::update_many()
            .col_expr(import_lists::Column::Enabled, Expr::value(new_enabled))
            .col_expr(
                import_lists::Column::UpdatedAt,
                now.into_simple_expr(backend),
            )
            .filter(Expr::col(import_lists::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("toggle import_list: {err}")))?;
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
        if !super::VALID_KINDS.contains(&payload.kind.trim()) {
            return Err(ServerFnError::new(format!(
                "kind {:?} must be one of {:?}",
                payload.kind,
                super::VALID_KINDS
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
