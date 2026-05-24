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
    use mydia_rs_db::insert_active_model;
    use mydia_rs_db::types::{DateTimeSecs, UuidText};
    use mydia_rs_entities::media_server_configs;
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

    fn model_to_row(m: &media_server_configs::Model) -> MediaServerRow {
        MediaServerRow {
            id: m.id.to_string(),
            name: m.name.clone(),
            kind: m.r#type.clone(),
            base_url: m.url.clone(),
            enabled: m.enabled.unwrap_or(false),
            inserted_at: Some(m.inserted_at.0.to_rfc3339()),
        }
    }

    pub(super) async fn list() -> Result<Vec<MediaServerRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let rows = media_server_configs::Entity::find()
            .order_by_asc(media_server_configs::Column::InsertedAt)
            .all(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("query media_servers: {err}")))?;
        Ok(rows.iter().map(model_to_row).collect())
    }

    pub(super) async fn create(payload: NewMediaServer) -> Result<MediaServerRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        validate(&payload)?;
        let st = state().await?;
        let id_uuid = uuid::Uuid::new_v4();
        let id_str = id_uuid.to_string();
        let id = UuidText::from(id_uuid);
        let now = DateTimeSecs::from(chrono::Utc::now());
        let am = media_server_configs::ActiveModel {
            id: Set(id),
            name: Set(payload.name.trim().to_owned()),
            r#type: Set(payload.kind.trim().to_owned()),
            enabled: Set(Some(payload.enabled)),
            url: Set(payload.base_url.trim().to_owned()),
            token: Set(payload.access_token.clone()),
            connection_settings: Set(None),
            updated_by_id: Set(None),
            inserted_at: Set(now),
            updated_at: Set(now),
        };
        insert_active_model(am, &st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("insert media_server: {err}")))?;
        Ok(MediaServerRow {
            id: id_str,
            name: payload.name.trim().to_owned(),
            kind: payload.kind.trim().to_owned(),
            base_url: payload.base_url.trim().to_owned(),
            enabled: payload.enabled,
            inserted_at: Some(now.0.to_rfc3339()),
        })
    }

    pub(super) async fn delete(id: String) -> Result<(), ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let Some(wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new(format!("invalid media_server id {id}")));
        };
        let backend = st.db.get_database_backend();
        let res = media_server_configs::Entity::delete_many()
            .filter(
                Expr::col(media_server_configs::Column::Id).eq(wrapper.into_simple_expr(backend)),
            )
            .exec(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("delete media_server: {err}")))?;
        if res.rows_affected == 0 {
            return Err(ServerFnError::new(format!("no media_server with id {id}")));
        }
        Ok(())
    }

    pub(super) async fn toggle(id: String) -> Result<MediaServerRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let Some(wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new(format!("invalid media_server id {id}")));
        };
        let backend = st.db.get_database_backend();
        let Some(row) = media_server_configs::Entity::find()
            .filter(
                Expr::col(media_server_configs::Column::Id).eq(wrapper.into_simple_expr(backend)),
            )
            .one(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("read media_server: {err}")))?
        else {
            return Err(ServerFnError::new(format!("no media_server with id {id}")));
        };
        let now = DateTimeSecs::from(chrono::Utc::now());
        let new_enabled = !row.enabled.unwrap_or(false);
        media_server_configs::Entity::update_many()
            .col_expr(
                media_server_configs::Column::Enabled,
                Expr::value(new_enabled),
            )
            .col_expr(
                media_server_configs::Column::UpdatedAt,
                now.into_simple_expr(backend),
            )
            .filter(
                Expr::col(media_server_configs::Column::Id).eq(wrapper.into_simple_expr(backend)),
            )
            .exec(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("toggle media_server: {err}")))?;
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
