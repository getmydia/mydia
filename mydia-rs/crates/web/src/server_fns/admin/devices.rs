//! Paired remote-device server functions.
//!
//! Phoenix counterpart: `MydiaWeb.AdminDevicesLive.Index` +
//! `Mydia.RemoteAccess`. The Phoenix page lists every paired device
//! for the current user and offers a single mutation (revoke).
//!
//! `remote_devices` schema (see
//! `priv/repo/migrations/20251225060000_create_remote_access_tables.exs`):
//! `id`, `device_name`, `platform`, `device_static_public_key`,
//! `token_hash`, `last_seen_at`, `revoked_at`, `user_id`,
//! `inserted_at`, `updated_at`.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceRow {
    pub id: String,
    pub device_name: String,
    pub platform: String,
    #[serde(default)]
    pub last_seen_at: Option<String>,
    #[serde(default)]
    pub revoked_at: Option<String>,
    pub inserted_at: Option<String>,
    /// Phoenix-style status keyword (`active` / `inactive` /
    /// `revoked`) the admin status pill maps from. Computed
    /// server-side because the recency cutoff needs `chrono`'s
    /// clock, which isn't wired on the wasm target.
    pub status: String,
}

#[get("/api/admin/devices")]
pub async fn list_devices() -> Result<Vec<DeviceRow>, ServerFnError> {
    server::list().await
}

#[post("/api/admin/devices/revoke")]
pub async fn revoke_device(id: String) -> Result<(), ServerFnError> {
    server::revoke(id).await
}

#[cfg(feature = "server")]
mod server {
    use super::DeviceRow;
    use crate::server_fns::auth::require_admin_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use mydia_rs_db::types::{DateTimeSecs, UuidText};
    use mydia_rs_db::DatabaseConnection;
    use mydia_rs_entities::remote_devices;
    use sea_orm::entity::prelude::*;
    use sea_orm::query::QueryOrder;
    use sea_orm::sea_query::{Expr, ExprTrait};

    async fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context".to_owned()))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState axum extension missing".to_owned()))
    }

    fn parse_uuid(s: &str) -> Option<UuidText> {
        uuid::Uuid::parse_str(s).ok().map(UuidText::from)
    }

    pub(super) async fn list() -> Result<Vec<DeviceRow>, ServerFnError> {
        let user_id = require_admin_user_id().await?;
        let state = state().await?;
        let Some(user_wrapper) = parse_uuid(&user_id) else {
            return Ok(Vec::new());
        };
        let backend = state.db.get_database_backend();
        let rows = remote_devices::Entity::find()
            .filter(
                Expr::col(remote_devices::Column::UserId)
                    .eq(user_wrapper.into_simple_expr(backend)),
            )
            .order_by_desc(remote_devices::Column::InsertedAt)
            .all(&state.db)
            .await
            .map_err(|err| ServerFnError::new(format!("query remote_devices: {err}")))?;
        let cutoff = chrono::Utc::now() - chrono::Duration::days(7);
        Ok(rows
            .into_iter()
            .map(|row| {
                let status = if row.revoked_at.is_some() {
                    "revoked"
                } else if row.last_seen_at.as_ref().is_some_and(|dt| dt.0 > cutoff) {
                    "active"
                } else {
                    "inactive"
                };
                DeviceRow {
                    id: row.id.to_string(),
                    device_name: row.device_name,
                    platform: row.platform,
                    last_seen_at: row.last_seen_at.map(|dt| dt.0.to_rfc3339()),
                    revoked_at: row.revoked_at.map(|dt| dt.0.to_rfc3339()),
                    inserted_at: Some(row.inserted_at.0.to_rfc3339()),
                    status: status.to_owned(),
                }
            })
            .collect())
    }

    pub(super) async fn revoke(id: String) -> Result<(), ServerFnError> {
        let user_id = require_admin_user_id().await?;
        let state = state().await?;
        let now = DateTimeSecs::from(chrono::Utc::now());
        let Some(dev_wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new(format!("invalid device id {id}")));
        };
        let Some(user_wrapper) = parse_uuid(&user_id) else {
            return Err(ServerFnError::new("invalid user id".to_owned()));
        };
        let backend = state.db.get_database_backend();
        let res = remote_devices::Entity::update_many()
            .col_expr(
                remote_devices::Column::RevokedAt,
                now.into_simple_expr(backend),
            )
            .col_expr(
                remote_devices::Column::UpdatedAt,
                now.into_simple_expr(backend),
            )
            .filter(Expr::col(remote_devices::Column::Id).eq(dev_wrapper.into_simple_expr(backend)))
            .filter(
                Expr::col(remote_devices::Column::UserId)
                    .eq(user_wrapper.into_simple_expr(backend)),
            )
            .exec(&state.db)
            .await
            .map_err(|err| ServerFnError::new(format!("revoke device: {err}")))?;
        if res.rows_affected == 0 {
            return Err(ServerFnError::new(format!(
                "no device with id {id} owned by the current user"
            )));
        }
        Ok(())
    }
}
