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
    use mydia_rs_db::Db;

    async fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context".to_owned()))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState axum extension missing".to_owned()))
    }

    type DeviceTuple = (
        String,
        String,
        String,
        Option<chrono::DateTime<chrono::Utc>>,
        Option<chrono::DateTime<chrono::Utc>>,
        Option<chrono::DateTime<chrono::Utc>>,
    );

    pub(super) async fn list() -> Result<Vec<DeviceRow>, ServerFnError> {
        let user_id = require_admin_user_id().await?;
        let state = state().await?;
        let rows: Vec<DeviceTuple> = match &state.db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT id, device_name, platform, last_seen_at, revoked_at, inserted_at \
                 FROM remote_devices WHERE user_id = ? \
                 ORDER BY inserted_at DESC",
            )
            .bind(&user_id)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query remote_devices: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT id, device_name, platform, last_seen_at, revoked_at, inserted_at \
                 FROM remote_devices WHERE user_id = $1 \
                 ORDER BY inserted_at DESC",
            )
            .bind(&user_id)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query remote_devices: {err}")))?,
        };
        let cutoff = chrono::Utc::now() - chrono::Duration::days(7);
        Ok(rows
            .into_iter()
            .map(
                |(id, device_name, platform, last_seen_at, revoked_at, inserted_at)| {
                    let status = if revoked_at.is_some() {
                        "revoked"
                    } else if last_seen_at.is_some_and(|dt| dt > cutoff) {
                        "active"
                    } else {
                        "inactive"
                    };
                    DeviceRow {
                        id,
                        device_name,
                        platform,
                        last_seen_at: last_seen_at.map(|dt| dt.to_rfc3339()),
                        revoked_at: revoked_at.map(|dt| dt.to_rfc3339()),
                        inserted_at: inserted_at.map(|dt| dt.to_rfc3339()),
                        status: status.to_owned(),
                    }
                },
            )
            .collect())
    }

    pub(super) async fn revoke(id: String) -> Result<(), ServerFnError> {
        let user_id = require_admin_user_id().await?;
        let state = state().await?;
        let now = chrono::Utc::now();

        // Constrain to the current user so an operator can't revoke
        // someone else's device by guessing IDs.
        let affected = match &state.db {
            Db::Sqlite(pool) => sqlx::query(
                "UPDATE remote_devices SET revoked_at = ?, updated_at = ? \
                 WHERE id = ? AND user_id = ?",
            )
            .bind(now.to_rfc3339())
            .bind(now.to_rfc3339())
            .bind(&id)
            .bind(&user_id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("revoke device: {err}")))?
            .rows_affected(),
            Db::Postgres(pool) => sqlx::query(
                "UPDATE remote_devices SET revoked_at = $1, updated_at = $2 \
                 WHERE id = $3 AND user_id = $4",
            )
            .bind(now)
            .bind(now)
            .bind(&id)
            .bind(&user_id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("revoke device: {err}")))?
            .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!(
                "no device with id {id} owned by the current user"
            )));
        }
        Ok(())
    }
}
