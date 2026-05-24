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
//!
//! The "Test connection" surface dispatches a live probe through
//! [`crate::indexer_probes::IndexerProbeCache`] — the cache reuses
//! `crates/indexers/`'s adapter trait so each kind runs its own
//! protocol-specific check. Probe results cache for 60s by default
//! to keep the admin "click around" UX cheap and to mirror the
//! download-client side.

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

/// Result of a "Test connection" probe through
/// [`crate::indexer_probes::IndexerProbeCache`]. The admin page
/// renders the message either way; success is just a checkmark next
/// to it.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ConnectionTest {
    pub ok: bool,
    pub message: String,
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

#[post("/api/admin/indexers/test")]
pub async fn test_indexer(id: String) -> Result<ConnectionTest, ServerFnError> {
    server::test(id).await
}

#[cfg(feature = "server")]
mod server {
    // TODO(broken-pre-conversion): the wire payload references a
    // `definition` column that the entity (`indexer_configs`) doesn't
    // have. The entity stores `type` (cardigann/prowlarr/jackett/
    // nzbhydra2) instead. Map `definition` → `r#type` so callers see a
    // working CRUD surface; the cardigann-YAML-name story will need a
    // separate column or a per-row JSON blob when the feature surfaces.
    use super::{ConnectionTest, IndexerRow, NewIndexer};
    use crate::server_fns::auth::require_admin_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use mydia_rs_db::types::{DateTimeSecs, UuidText};
    use mydia_rs_db::{insert_active_model, DatabaseConnection};
    use mydia_rs_entities::indexer_configs;
    use mydia_rs_indexers::adapter::{AdapterConfig, AdapterKind};
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

    fn model_to_row(m: &indexer_configs::Model) -> IndexerRow {
        IndexerRow {
            id: m.id.to_string(),
            name: m.name.clone(),
            definition: m.r#type.clone(),
            base_url: m.base_url.clone().unwrap_or_default(),
            enabled: m.enabled.unwrap_or(false),
            inserted_at: Some(m.inserted_at.0.to_rfc3339()),
        }
    }

    pub(super) async fn list() -> Result<Vec<IndexerRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let rows = indexer_configs::Entity::find()
            .order_by_asc(indexer_configs::Column::InsertedAt)
            .all(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("query indexers: {err}")))?;
        Ok(rows.iter().map(model_to_row).collect())
    }

    pub(super) async fn create(payload: NewIndexer) -> Result<IndexerRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        validate(&payload)?;
        let st = state().await?;

        let id_uuid = uuid::Uuid::new_v4();
        let id_str = id_uuid.to_string();
        let id = UuidText::from(id_uuid);
        let now = DateTimeSecs::from(chrono::Utc::now());
        let am = indexer_configs::ActiveModel {
            id: Set(id),
            name: Set(payload.name.trim().to_owned()),
            r#type: Set(payload.definition.trim().to_owned()),
            enabled: Set(Some(payload.enabled)),
            priority: Set(None),
            base_url: Set(Some(payload.base_url.trim().to_owned())),
            api_key: Set(payload.api_key.clone()),
            rate_limit: Set(None),
            connection_settings: Set(None),
            updated_by_id: Set(None),
            inserted_at: Set(now),
            updated_at: Set(now),
            env_name: Set(None),
            indexer_ids: Set(None),
            categories: Set(None),
            min_post_age_minutes: Set(None),
        };
        insert_active_model(am, &st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("insert indexer: {err}")))?;
        Ok(IndexerRow {
            id: id_str,
            name: payload.name.trim().to_owned(),
            definition: payload.definition.trim().to_owned(),
            base_url: payload.base_url.trim().to_owned(),
            enabled: payload.enabled,
            inserted_at: Some(now.0.to_rfc3339()),
        })
    }

    pub(super) async fn delete(id: String) -> Result<(), ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let Some(wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new(format!("invalid indexer id {id}")));
        };
        let backend = st.db.get_database_backend();
        let res = indexer_configs::Entity::delete_many()
            .filter(Expr::col(indexer_configs::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("delete indexer: {err}")))?;
        if res.rows_affected == 0 {
            return Err(ServerFnError::new(format!("no indexer with id {id}")));
        }
        st.indexer_probes.invalidate(&id);
        Ok(())
    }

    pub(super) async fn toggle(id: String) -> Result<IndexerRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let Some(wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new(format!("invalid indexer id {id}")));
        };
        // SeaORM's typed builder doesn't have a "negate column" op so
        // read-then-write. This is a per-row toggle; the round-trip is
        // negligible.
        let backend = st.db.get_database_backend();
        let Some(row) = indexer_configs::Entity::find()
            .filter(Expr::col(indexer_configs::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .one(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("read indexer: {err}")))?
        else {
            return Err(ServerFnError::new(format!("no indexer with id {id}")));
        };
        let now = DateTimeSecs::from(chrono::Utc::now());
        let new_enabled = !row.enabled.unwrap_or(false);
        indexer_configs::Entity::update_many()
            .col_expr(indexer_configs::Column::Enabled, Expr::value(new_enabled))
            .col_expr(
                indexer_configs::Column::UpdatedAt,
                now.into_simple_expr(backend),
            )
            .filter(Expr::col(indexer_configs::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("toggle indexer: {err}")))?;
        // Operator-intent invalidation: toggling enabled doesn't change
        // connectivity, but the operator's intent on this surface is "I
        // changed something" — drop the cached entry so the next Test
        // reflects the current state without the user wondering whether
        // they're seeing a stale 60s-old result.
        st.indexer_probes.invalidate(&id);
        list()
            .await?
            .into_iter()
            .find(|r| r.id == id)
            .ok_or_else(|| {
                ServerFnError::new("indexer disappeared between update and read".to_owned())
            })
    }

    pub(super) async fn test(id: String) -> Result<ConnectionTest, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let Some(wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new(format!("invalid indexer id {id}")));
        };
        let backend = st.db.get_database_backend();
        let Some(row) = indexer_configs::Entity::find()
            .filter(Expr::col(indexer_configs::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .one(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("read indexer: {err}")))?
        else {
            return Err(ServerFnError::new(format!("no indexer with id {id}")));
        };

        // The admin page treats every row as Cardigann-backed (the
        // page is explicitly named the "Cardigann-backed sources"
        // surface in its description); the per-row `r#type`
        // identifies which YAML drives the engine, not a different
        // adapter kind.
        let config = AdapterConfig {
            r#type: AdapterKind::Cardigann,
            name: row.name,
            base_url: row.base_url.unwrap_or_default(),
            api_key: row.api_key,
            options: serde_json::Value::Null,
            id: id.clone(),
            rate_limit: None,
        };

        let entry = st
            .indexer_probes
            .probe(&id, AdapterKind::Cardigann, config)
            .await;
        Ok(ConnectionTest {
            ok: entry.ok,
            message: entry.message,
        })
    }
    // Stop unused-import warnings in case some imports above end up unused.
    #[allow(dead_code)]
    fn _silence_warnings(_db: &DatabaseConnection) {}

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
