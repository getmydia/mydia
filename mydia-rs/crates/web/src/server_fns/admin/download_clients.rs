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
    use super::{ConnectionTest, DownloadClientRow, NewDownloadClient, VALID_KINDS};
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
        bool,
        Option<chrono::DateTime<chrono::Utc>>,
    );

    pub(super) async fn list() -> Result<Vec<DownloadClientRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let rows: Vec<Row> = match &st.db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT id, name, kind, url, username, enabled, inserted_at \
                 FROM download_clients ORDER BY inserted_at ASC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query download_clients: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT id, name, kind, url, username, enabled, inserted_at \
                 FROM download_clients ORDER BY inserted_at ASC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query download_clients: {err}")))?,
        };
        Ok(rows
            .into_iter()
            .map(
                |(id, name, kind, url, username, enabled, inserted_at)| DownloadClientRow {
                    id,
                    name,
                    kind,
                    url,
                    username,
                    enabled,
                    inserted_at: inserted_at.map(|dt| dt.to_rfc3339()),
                },
            )
            .collect())
    }

    pub(super) async fn create(
        payload: NewDownloadClient,
    ) -> Result<DownloadClientRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        validate(&payload)?;
        let st = state().await?;

        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now();
        match &st.db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "INSERT INTO download_clients (id, name, kind, url, username, password, enabled, inserted_at, updated_at) \
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                )
                .bind(&id)
                .bind(payload.name.trim())
                .bind(payload.kind.trim())
                .bind(payload.url.trim())
                .bind(payload.username.as_deref())
                .bind(payload.password.as_deref())
                .bind(payload.enabled)
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert download_client: {err}")))?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "INSERT INTO download_clients (id, name, kind, url, username, password, enabled, inserted_at, updated_at) \
                     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
                )
                .bind(&id)
                .bind(payload.name.trim())
                .bind(payload.kind.trim())
                .bind(payload.url.trim())
                .bind(payload.username.as_deref())
                .bind(payload.password.as_deref())
                .bind(payload.enabled)
                .bind(now)
                .bind(now)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert download_client: {err}")))?;
            }
        }

        Ok(DownloadClientRow {
            id,
            name: payload.name.trim().to_owned(),
            kind: payload.kind.trim().to_owned(),
            url: payload.url.trim().to_owned(),
            username: payload.username.clone(),
            enabled: payload.enabled,
            inserted_at: Some(now.to_rfc3339()),
        })
    }

    pub(super) async fn delete(id: String) -> Result<(), ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let affected = match &st.db {
            Db::Sqlite(pool) => sqlx::query("DELETE FROM download_clients WHERE id = ?")
                .bind(&id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("delete download_client: {err}")))?
                .rows_affected(),
            Db::Postgres(pool) => sqlx::query("DELETE FROM download_clients WHERE id = $1")
                .bind(&id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("delete download_client: {err}")))?
                .rows_affected(),
        };
        if affected == 0 {
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
        let now = chrono::Utc::now();
        // SQLite + Postgres both support `NOT enabled` in an
        // expression; one query covers both adapters.
        let affected = match &st.db {
            Db::Sqlite(pool) => sqlx::query(
                "UPDATE download_clients SET enabled = NOT enabled, updated_at = ? WHERE id = ?",
            )
            .bind(now.to_rfc3339())
            .bind(&id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("toggle download_client: {err}")))?
            .rows_affected(),
            Db::Postgres(pool) => sqlx::query(
                "UPDATE download_clients SET enabled = NOT enabled, updated_at = $1 WHERE id = $2",
            )
            .bind(now)
            .bind(&id)
            .execute(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("toggle download_client: {err}")))?
            .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!(
                "no download_client with id {id}"
            )));
        }
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
        type Row = (String, String, String, Option<String>, Option<String>);
        let row: Option<Row> = match &st.db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT kind, url, name, username, password FROM download_clients \
                 WHERE id = ? LIMIT 1",
            )
            .bind(&id)
            .fetch_optional(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("read download_client: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT kind, url, name, username, password FROM download_clients \
                 WHERE id = $1 LIMIT 1",
            )
            .bind(&id)
            .fetch_optional(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("read download_client: {err}")))?,
        };
        let Some((kind, url, _name, username, password)) = row else {
            return Err(ServerFnError::new(format!(
                "no download_client with id {id}"
            )));
        };

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
