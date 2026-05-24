//! Download-client management server functions.
//!
//! Phoenix counterpart: `MydiaWeb.AdminDownloadClientsLive`. The
//! Phoenix page configures the supported clients (qBittorrent,
//! Transmission, rTorrent, `SABnzbd`, `NZBGet`, Debrid services, plus
//! blackhole as the fallback). Each row is a `(kind, name, url,
//! username, password, enabled)` tuple persisted to
//! `download_clients`.
//!
//! Validation rules mirror the Phoenix schema:
//! - `name` non-blank.
//! - `kind` in the small enum set.
//! - `url` non-blank; we don't enforce a scheme here because
//!   downstream clients accept paths (blackhole) and bare hostnames
//!   (transmission RPC).
//!
//! The "Test connection" surface dispatches a live probe through
//! [`crate::download_probes::ProbeCache`] — the cache reuses
//! `crates/downloads/`'s adapter trait so each kind runs its own
//! protocol-specific check (qBittorrent API auth, Transmission RPC
//! ping, etc.). Probe results cache for 60s by default to keep the
//! admin "click around" UX cheap.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DownloadClientRow {
    pub id: String,
    pub name: String,
    /// `qbittorrent` / `transmission` / `rtorrent` / `sabnzbd` /
    /// `nzbget` / `debrid` / `blackhole`.
    pub kind: String,
    pub url: String,
    #[serde(default)]
    pub username: Option<String>,
    pub enabled: bool,
    pub inserted_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct NewDownloadClient {
    pub name: String,
    pub kind: String,
    pub url: String,
    #[serde(default)]
    pub username: Option<String>,
    #[serde(default)]
    pub password: Option<String>,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

const fn default_enabled() -> bool {
    true
}

/// Result of a "Test connection" probe. The page renders the
/// message either way; success is just a checkmark next to it.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ConnectionTest {
    pub ok: bool,
    pub message: String,
}

pub const VALID_KINDS: &[&str] = &[
    "qbittorrent",
    "transmission",
    "rtorrent",
    "sabnzbd",
    "nzbget",
    "debrid",
    "blackhole",
];

#[get("/api/admin/download_clients")]
pub async fn list_download_clients() -> Result<Vec<DownloadClientRow>, ServerFnError> {
    server::list().await
}

#[post("/api/admin/download_clients")]
pub async fn create_download_client(
    payload: NewDownloadClient,
) -> Result<DownloadClientRow, ServerFnError> {
    server::create(payload).await
}

#[post("/api/admin/download_clients/delete")]
pub async fn delete_download_client(id: String) -> Result<(), ServerFnError> {
    server::delete(id).await
}

#[post("/api/admin/download_clients/toggle")]
pub async fn toggle_download_client(id: String) -> Result<DownloadClientRow, ServerFnError> {
    server::toggle(id).await
}

#[post("/api/admin/download_clients/test")]
pub async fn test_download_client(id: String) -> Result<ConnectionTest, ServerFnError> {
    server::test(id).await
}

#[cfg(feature = "server")]
mod server {
    // The page's wire payload uses `kind` and `url`; the entity's
    // columns are `r#type` and `host`. Map back-and-forth at the seam.
    use super::{ConnectionTest, DownloadClientRow, NewDownloadClient, VALID_KINDS};
    use crate::server_fns::auth::require_admin_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use mydia_rs_db::insert_active_model;
    use mydia_rs_db::types::{DateTimeSecs, UuidText};
    use mydia_rs_entities::download_client_configs;
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

    fn model_to_row(m: &download_client_configs::Model) -> DownloadClientRow {
        DownloadClientRow {
            id: m.id.to_string(),
            name: m.name.clone(),
            kind: m.r#type.clone(),
            url: m.host.clone().unwrap_or_default(),
            username: m.username.clone(),
            enabled: m.enabled.unwrap_or(false),
            inserted_at: Some(m.inserted_at.0.to_rfc3339()),
        }
    }

    pub(super) async fn list() -> Result<Vec<DownloadClientRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let rows = download_client_configs::Entity::find()
            .order_by_asc(download_client_configs::Column::InsertedAt)
            .all(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("query download_clients: {err}")))?;
        Ok(rows.iter().map(model_to_row).collect())
    }

    pub(super) async fn create(
        payload: NewDownloadClient,
    ) -> Result<DownloadClientRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        validate(&payload)?;
        let st = state().await?;

        let id_uuid = uuid::Uuid::new_v4();
        let id_str = id_uuid.to_string();
        let id = UuidText::from(id_uuid);
        let now = DateTimeSecs::from(chrono::Utc::now());
        let am = download_client_configs::ActiveModel {
            id: Set(id),
            name: Set(payload.name.trim().to_owned()),
            r#type: Set(payload.kind.trim().to_owned()),
            enabled: Set(Some(payload.enabled)),
            priority: Set(None),
            host: Set(Some(payload.url.trim().to_owned())),
            port: Set(None),
            use_ssl: Set(None),
            url_base: Set(None),
            username: Set(payload.username.clone()),
            password: Set(payload.password.clone()),
            api_key: Set(None),
            category: Set(None),
            download_directory: Set(None),
            connection_settings: Set(None),
            updated_by_id: Set(None),
            inserted_at: Set(now),
            updated_at: Set(now),
            remove_completed: Set(None),
            categories: Set(None),
            priority_profile: Set(None),
            incomplete_grace_minutes: Set(None),
        };
        insert_active_model(am, &st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("insert download_client: {err}")))?;

        Ok(DownloadClientRow {
            id: id_str,
            name: payload.name.trim().to_owned(),
            kind: payload.kind.trim().to_owned(),
            url: payload.url.trim().to_owned(),
            username: payload.username.clone(),
            enabled: payload.enabled,
            inserted_at: Some(now.0.to_rfc3339()),
        })
    }

    pub(super) async fn delete(id: String) -> Result<(), ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let Some(wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new(format!(
                "invalid download_client id {id}"
            )));
        };
        let backend = st.db.get_database_backend();
        let res = download_client_configs::Entity::delete_many()
            .filter(
                Expr::col(download_client_configs::Column::Id)
                    .eq(wrapper.into_simple_expr(backend)),
            )
            .exec(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("delete download_client: {err}")))?;
        if res.rows_affected == 0 {
            return Err(ServerFnError::new(format!(
                "no download_client with id {id}"
            )));
        }
        st.download_probes.invalidate(&id);
        Ok(())
    }

    pub(super) async fn toggle(id: String) -> Result<DownloadClientRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let Some(wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new(format!(
                "invalid download_client id {id}"
            )));
        };
        let backend = st.db.get_database_backend();
        let Some(row) = download_client_configs::Entity::find()
            .filter(
                Expr::col(download_client_configs::Column::Id)
                    .eq(wrapper.into_simple_expr(backend)),
            )
            .one(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("read download_client: {err}")))?
        else {
            return Err(ServerFnError::new(format!(
                "no download_client with id {id}"
            )));
        };
        let now = DateTimeSecs::from(chrono::Utc::now());
        let new_enabled = !row.enabled.unwrap_or(false);
        download_client_configs::Entity::update_many()
            .col_expr(
                download_client_configs::Column::Enabled,
                Expr::value(new_enabled),
            )
            .col_expr(
                download_client_configs::Column::UpdatedAt,
                now.into_simple_expr(backend),
            )
            .filter(
                Expr::col(download_client_configs::Column::Id)
                    .eq(wrapper.into_simple_expr(backend)),
            )
            .exec(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("toggle download_client: {err}")))?;
        // Toggling enabled doesn't change connectivity, but the
        // operator's intent on this surface is "I changed something"
        // — drop the cached entry so the next Test reflects the
        // current state without the user wondering whether they're
        // seeing a stale 60s-old result.
        st.download_probes.invalidate(&id);
        list()
            .await?
            .into_iter()
            .find(|r| r.id == id)
            .ok_or_else(|| {
                ServerFnError::new("download_client disappeared between update and read".to_owned())
            })
    }

    pub(super) async fn test(id: String) -> Result<ConnectionTest, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let Some(wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new(format!(
                "invalid download_client id {id}"
            )));
        };
        let backend = st.db.get_database_backend();
        let Some(row) = download_client_configs::Entity::find()
            .filter(
                Expr::col(download_client_configs::Column::Id)
                    .eq(wrapper.into_simple_expr(backend)),
            )
            .one(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("read download_client: {err}")))?
        else {
            return Err(ServerFnError::new(format!(
                "no download_client with id {id}"
            )));
        };
        let kind = row.r#type;
        let url = row.host.unwrap_or_default();
        let username = row.username;
        let password = row.password;

        if !VALID_KINDS.contains(&kind.as_str()) {
            return Ok(ConnectionTest {
                ok: false,
                message: format!("unknown client kind {kind:?}"),
            });
        }

        // Blackhole + similar "drop into a folder" adapters use an
        // absolute path rather than an HTTP URL. They don't have a
        // meaningful network probe; surface a configuration-OK
        // message and short-circuit.
        if url.starts_with('/') {
            return Ok(ConnectionTest {
                ok: true,
                message: format!("{kind}: watch folder configured at {url:?}"),
            });
        }

        let config = match crate::download_probes::config_from_url(
            &url,
            username.as_deref(),
            password.as_deref(),
        ) {
            Ok(cfg) => cfg,
            Err(err) => {
                return Ok(ConnectionTest {
                    ok: false,
                    message: format!("invalid url: {err}"),
                });
            }
        };

        let entry = st.download_probes.probe(&id, &kind, config).await;
        Ok(ConnectionTest {
            ok: entry.ok,
            message: entry.message,
        })
    }

    fn validate(payload: &NewDownloadClient) -> Result<(), ServerFnError> {
        if payload.name.trim().is_empty() {
            return Err(ServerFnError::new("Name is required".to_owned()));
        }
        if !VALID_KINDS.contains(&payload.kind.trim()) {
            return Err(ServerFnError::new(format!(
                "kind {:?} must be one of {VALID_KINDS:?}",
                payload.kind
            )));
        }
        if payload.url.trim().is_empty() {
            return Err(ServerFnError::new("URL is required".to_owned()));
        }
        Ok(())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn validate_rejects_blank_name() {
            let result = validate(&NewDownloadClient {
                name: "  ".into(),
                kind: "qbittorrent".into(),
                url: "http://localhost".into(),
                ..Default::default()
            });
            assert!(result.is_err());
        }

        #[test]
        fn validate_rejects_unknown_kind() {
            let result = validate(&NewDownloadClient {
                name: "x".into(),
                kind: "magnet".into(),
                url: "http://localhost".into(),
                ..Default::default()
            });
            assert!(result.is_err());
        }

        #[test]
        fn validate_accepts_known_kind() {
            let result = validate(&NewDownloadClient {
                name: "qb".into(),
                kind: "qbittorrent".into(),
                url: "http://localhost:8080".into(),
                ..Default::default()
            });
            assert!(result.is_ok());
        }
    }
}
