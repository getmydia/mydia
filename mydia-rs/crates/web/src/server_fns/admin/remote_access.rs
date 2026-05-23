//! Remote-access (p2p paired-device) administration.
//!
//! Phoenix counterpart: `MydiaWeb.AdminRemoteAccessLive`. Lists every
//! paired remote device across all users — operator's view of the
//! mesh, distinct from the user-facing devices page (which scopes
//! to one user).
//!
//! Note this is separate from the operational `pages/admin/devices`
//! page; that one is the user-scoped device list used to inspect a
//! single user's mesh participation.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairedDeviceRow {
    pub id: String,
    pub device_name: String,
    pub platform: String,
    pub user_id: String,
    #[serde(default)]
    pub user_label: Option<String>,
    pub last_seen_at: Option<String>,
    pub revoked_at: Option<String>,
    pub inserted_at: Option<String>,
}

/// Snapshot of the local p2p node — node id, listen addresses,
/// discovery counts. Sourced from the cached
/// [`crate::server_state::WebState`]; we don't poke the live core
/// crate here because the live state-machine is held by the app
/// boot path and exposing it through Dioxus context is U29's job.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct P2pStatus {
    /// Stable identifier (Iroh node id, formatted hex).
    pub node_id: String,
    pub paired_devices: i64,
    pub revoked_devices: i64,
    #[serde(default)]
    pub last_seen_summary: Option<String>,
}

#[get("/api/admin/remote_access/devices")]
pub async fn list_paired_devices() -> Result<Vec<PairedDeviceRow>, ServerFnError> {
    server::list().await
}

#[post("/api/admin/remote_access/revoke")]
pub async fn revoke_paired_device(id: String) -> Result<(), ServerFnError> {
    server::revoke(id).await
}

#[get("/api/admin/remote_access/status")]
pub async fn remote_access_status() -> Result<P2pStatus, ServerFnError> {
    server::status().await
}

#[cfg(feature = "server")]
mod server {
    use super::{P2pStatus, PairedDeviceRow};
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
        Option<String>,
        Option<chrono::DateTime<chrono::Utc>>,
        Option<chrono::DateTime<chrono::Utc>>,
        Option<chrono::DateTime<chrono::Utc>>,
    );

    pub(super) async fn list() -> Result<Vec<PairedDeviceRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let rows: Vec<Row> = match &st.db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT d.id, d.device_name, d.platform, d.user_id, \
                        COALESCE(u.username, u.email, u.id), \
                        d.last_seen_at, d.revoked_at, d.inserted_at \
                 FROM remote_devices d \
                 LEFT JOIN users u ON u.id = d.user_id \
                 ORDER BY d.inserted_at DESC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query remote_devices: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT d.id, d.device_name, d.platform, d.user_id, \
                        COALESCE(u.username, u.email, u.id), \
                        d.last_seen_at, d.revoked_at, d.inserted_at \
                 FROM remote_devices d \
                 LEFT JOIN users u ON u.id = d.user_id \
                 ORDER BY d.inserted_at DESC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query remote_devices: {err}")))?,
        };

        Ok(rows
            .into_iter()
            .map(
                |(
                    id,
                    device_name,
                    platform,
                    user_id,
                    user_label,
                    last_seen_at,
                    revoked_at,
                    inserted_at,
                )| {
                    PairedDeviceRow {
                        id,
                        device_name,
                        platform,
                        user_id,
                        user_label,
                        last_seen_at: last_seen_at.map(|dt| dt.to_rfc3339()),
                        revoked_at: revoked_at.map(|dt| dt.to_rfc3339()),
                        inserted_at: inserted_at.map(|dt| dt.to_rfc3339()),
                    }
                },
            )
            .collect())
    }

    pub(super) async fn revoke(id: String) -> Result<(), ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let now = chrono::Utc::now();
        let affected = match &st.db {
            Db::Sqlite(pool) => {
                sqlx::query("UPDATE remote_devices SET revoked_at = ?, updated_at = ? WHERE id = ?")
                    .bind(now.to_rfc3339())
                    .bind(now.to_rfc3339())
                    .bind(&id)
                    .execute(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("revoke device: {err}")))?
                    .rows_affected()
            }
            Db::Postgres(pool) => sqlx::query(
                "UPDATE remote_devices SET revoked_at = $1, updated_at = $2 WHERE id = $3",
            )
            .bind(now)
            .bind(now)
            .bind(&id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("revoke device: {err}")))?
            .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!("no device with id {id}")));
        }
        Ok(())
    }

    pub(super) async fn status() -> Result<P2pStatus, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        // The live p2p Host handle isn't part of WebState yet; until
        // U29 wires it through, we surface the persisted-device
        // counts so the page renders something useful out of the
        // box.
        let (paired,): (i64,) = match &st.db {
            Db::Sqlite(pool) => {
                sqlx::query_as("SELECT COUNT(*) FROM remote_devices WHERE revoked_at IS NULL")
                    .fetch_one(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("count paired: {err}")))?
            }
            Db::Postgres(pool) => {
                sqlx::query_as("SELECT COUNT(*) FROM remote_devices WHERE revoked_at IS NULL")
                    .fetch_one(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("count paired: {err}")))?
            }
        };
        let (revoked,): (i64,) = match &st.db {
            Db::Sqlite(pool) => {
                sqlx::query_as("SELECT COUNT(*) FROM remote_devices WHERE revoked_at IS NOT NULL")
                    .fetch_one(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("count revoked: {err}")))?
            }
            Db::Postgres(pool) => {
                sqlx::query_as("SELECT COUNT(*) FROM remote_devices WHERE revoked_at IS NOT NULL")
                    .fetch_one(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("count revoked: {err}")))?
            }
        };

        Ok(P2pStatus {
            node_id: "(p2p host handle not yet wired into WebState — U29 follow-up)".to_owned(),
            paired_devices: paired,
            revoked_devices: revoked,
            last_seen_summary: None,
        })
    }
}
