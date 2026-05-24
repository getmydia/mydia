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
/// discovery counts. The DB-counted device totals are always set; the
/// live fields (`node_id`, `connected_peers`, `relay_*`, `node_addr`)
/// stay at their defaults when the p2p Server is not running (remote
/// access disabled in config, or boot path skipped it because no
/// keypair was configured).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct P2pStatus {
    /// Stable identifier (Iroh node id, formatted hex). Empty when
    /// the p2p Server is not running.
    pub node_id: String,
    pub paired_devices: i64,
    pub revoked_devices: i64,
    #[serde(default)]
    pub last_seen_summary: Option<String>,
    /// `true` when the p2p Server is constructed and the drain loop
    /// is running. The admin page conditionally renders the "Live
    /// host status" section on this flag.
    #[serde(default)]
    pub running: bool,
    /// Number of currently connected p2p peers (from the Host's
    /// network stats).
    #[serde(default)]
    pub connected_peers: i64,
    /// `true` when the Host has dialled a relay successfully.
    #[serde(default)]
    pub relay_connected: bool,
    /// Relay URL currently in use, if any.
    #[serde(default)]
    pub relay_url: Option<String>,
    /// Cached `EndpointAddr` JSON returned by the Host. Pasteable into
    /// the player's "manual dial" field when DHT/mDNS discovery is
    /// unavailable.
    #[serde(default)]
    pub node_addr: Option<String>,
    /// Connection type of the first connected peer (per the Host's
    /// `PeerConnectionType`). Useful diagnostic for "are we relayed
    /// or direct?".
    #[serde(default)]
    pub peer_connection_type: Option<String>,
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
    use mydia_rs_db::types::{DateTimeSecs, UuidText};
    use mydia_rs_entities::{remote_devices, users};
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

    pub(super) async fn list() -> Result<Vec<PairedDeviceRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let devices = remote_devices::Entity::find()
            .order_by_desc(remote_devices::Column::InsertedAt)
            .all(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("query remote_devices: {err}")))?;

        // Pull users with a single round-trip for the label.
        let user_ids: Vec<UuidText> = devices.iter().map(|d| d.user_id).collect();
        let user_rows = users::Entity::find()
            .filter(users::Column::Id.is_in(user_ids))
            .all(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("query users: {err}")))?;
        let user_map: std::collections::HashMap<UuidText, users::Model> =
            user_rows.into_iter().map(|u| (u.id, u)).collect();

        Ok(devices
            .into_iter()
            .map(|d| {
                let user_label = user_map.get(&d.user_id).and_then(|u| {
                    u.username
                        .clone()
                        .or_else(|| u.email.clone())
                        .or_else(|| Some(u.id.to_string()))
                });
                PairedDeviceRow {
                    id: d.id.to_string(),
                    device_name: d.device_name,
                    platform: d.platform,
                    user_id: d.user_id.to_string(),
                    user_label,
                    last_seen_at: d.last_seen_at.map(|dt| dt.0.to_rfc3339()),
                    revoked_at: d.revoked_at.map(|dt| dt.0.to_rfc3339()),
                    inserted_at: Some(d.inserted_at.0.to_rfc3339()),
                }
            })
            .collect())
    }

    pub(super) async fn revoke(id: String) -> Result<(), ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let Some(wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new(format!("invalid device id {id}")));
        };
        let backend = st.db.get_database_backend();
        let now = DateTimeSecs::from(chrono::Utc::now());
        let res = remote_devices::Entity::update_many()
            .col_expr(
                remote_devices::Column::RevokedAt,
                now.into_simple_expr(backend),
            )
            .col_expr(
                remote_devices::Column::UpdatedAt,
                now.into_simple_expr(backend),
            )
            .filter(Expr::col(remote_devices::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("revoke device: {err}")))?;
        if res.rows_affected == 0 {
            return Err(ServerFnError::new(format!("no device with id {id}")));
        }
        let _ = Set::<DateTimeSecs>; // silence unused-import lint when Set is otherwise not used
        Ok(())
    }

    pub(super) async fn status() -> Result<P2pStatus, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let paired = remote_devices::Entity::find()
            .filter(remote_devices::Column::RevokedAt.is_null())
            .count(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("count paired: {err}")))?;
        let paired = i64::try_from(paired).unwrap_or(i64::MAX);
        let revoked = remote_devices::Entity::find()
            .filter(remote_devices::Column::RevokedAt.is_not_null())
            .count(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("count revoked: {err}")))?;
        let revoked = i64::try_from(revoked).unwrap_or(i64::MAX);

        // The live p2p Server handle (U28 follow-up) — when present,
        // ask it for the Iroh node id, connection counts, and relay
        // state. When absent, the live fields stay at their defaults
        // and the page hides the "Live host status" section.
        let mut out = P2pStatus {
            node_id: String::new(),
            paired_devices: paired,
            revoked_devices: revoked,
            last_seen_summary: None,
            ..Default::default()
        };

        if let Some(handle) = st.p2p_server.as_ref() {
            // The Server's drain loop maintains a cached `ServerStatus`
            // we can read without blocking; the more-detailed
            // `network_stats()` and `get_node_addr()` calls wrap the
            // blocking Host APIs in `spawn_blocking` per the U29
            // discipline.
            let cached = handle.status().await;
            out.running = cached.running;
            out.node_id = cached.node_id.clone();
            out.relay_connected = cached.relay_connected;
            // The cached `connected_peers` count is updated from the
            // drain loop; freshen with a live network_stats read so the
            // operator sees the same number the host's own view of
            // peers reports.
            match handle.network_stats().await {
                Ok(stats) => {
                    out.connected_peers = stats.connected_peers as i64;
                    out.relay_connected = stats.relay_connected;
                    out.relay_url.clone_from(&stats.relay_url);
                    out.peer_connection_type = Some(stats.peer_connection_type.as_str().into());
                }
                Err(err) => {
                    tracing::warn!(error = %err, "p2p network_stats lookup failed; falling back to cached counts");
                    out.connected_peers = cached.connected_peers as i64;
                    out.relay_url.clone_from(&cached.relay_url);
                    out.peer_connection_type
                        .clone_from(&cached.peer_connection_type);
                }
            }
            match handle.get_node_addr().await {
                Ok(addr) => out.node_addr = Some(addr),
                Err(err) => {
                    tracing::warn!(error = %err, "p2p get_node_addr lookup failed");
                    out.node_addr = cached.node_addr.clone();
                }
            }
        }

        Ok(out)
    }
}
