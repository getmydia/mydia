//! System status server functions.
//!
//! Phoenix counterpart: `MydiaWeb.AdminSystemLive.Index`'s
//! `load_data` / `load_system_data` helpers. The Phoenix page
//! displays a read-only snapshot of process + database health plus
//! a handful of summary counts (library paths configured, download
//! clients configured, indexers configured). mydia-rs ports the
//! same surface — we don't show Oban depth (apalis port replaces
//! Oban; deeper job introspection lives on the jobs page already).
//!
//! Everything here is read-only. No mutations, no validation rules
//! to mirror beyond the role gate that every admin server fn
//! already shares.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Top-level system snapshot the admin status page renders.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct SystemStatus {
    pub app_version: String,
    pub build_target: String,
    /// `sqlite` or `postgres`.
    pub database_adapter: String,
    pub database_health: String,
    /// Pretty-printed database size (`12.4 MB`) or `unknown`.
    pub database_size: String,
    /// `SQLite` path or Postgres `host:port/db`.
    pub database_location: String,
    /// Process uptime as `1d 4h` / `12m 3s`.
    pub uptime: String,
    pub library_paths_count: i64,
    pub download_clients_count: i64,
    pub indexers_count: i64,
    pub active_transcodes: i64,
    pub active_streaming_sessions: i64,
}

#[get("/api/admin/system/status")]
pub async fn system_status() -> Result<SystemStatus, ServerFnError> {
    server::status().await
}

#[cfg(feature = "server")]
mod server {
    use super::SystemStatus;
    use crate::server_fns::auth::require_admin_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use mydia_rs_db::DatabaseConnection;
    use mydia_rs_entities::{
        download_client_configs, indexer_configs, library_paths, transcode_jobs,
    };
    use sea_orm::entity::prelude::*;
    use sea_orm::{ConnectionTrait, DatabaseBackend, Statement};
    use std::sync::OnceLock;
    use std::time::Instant;

    /// First-load timestamp used to derive the process uptime. The
    /// `JobStorage` clock would do too, but we already need a
    /// process-local handle here for the system surface and the
    /// `OnceLock` keeps the first-read price negligible.
    static BOOT: OnceLock<Instant> = OnceLock::new();

    async fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context".to_owned()))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState axum extension missing".to_owned()))
    }

    pub(super) async fn status() -> Result<SystemStatus, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let boot = *BOOT.get_or_init(Instant::now);
        let uptime = format_uptime(boot.elapsed());

        let (adapter, location) = describe_db(&st.db);
        let (size, health) = match probe_db(&st.db).await {
            Ok(ok) => ok,
            Err(err) => {
                tracing::warn!(%err, "system status DB probe failed");
                ("unknown".to_owned(), "unhealthy".to_owned())
            }
        };

        let library_paths_count = library_paths::Entity::find()
            .count(&st.db)
            .await
            .map(|n| i64::try_from(n).unwrap_or(i64::MAX))
            .unwrap_or(0);
        let download_clients_count = download_client_configs::Entity::find()
            .count(&st.db)
            .await
            .map(|n| i64::try_from(n).unwrap_or(i64::MAX))
            .unwrap_or(0);
        let indexers_count = indexer_configs::Entity::find()
            .count(&st.db)
            .await
            .map(|n| i64::try_from(n).unwrap_or(i64::MAX))
            .unwrap_or(0);
        let active_transcodes = transcode_jobs::Entity::find()
            .filter(transcode_jobs::Column::Status.is_in([
                "pending".to_owned(),
                "transcoding".to_owned(),
                "playing".to_owned(),
            ]))
            .count(&st.db)
            .await
            .map(|n| i64::try_from(n).unwrap_or(i64::MAX))
            .unwrap_or(0);
        // `streaming_sessions` doesn't exist as an entity (Phoenix's
        // streaming-session state lives in process memory, not the DB);
        // surface zero so the page renders without an extra plumbing
        // step. TODO(broken-pre-conversion): swap to whatever sentinel
        // the streaming supervisor surfaces once it grows an
        // active-session count getter.
        let active_streaming_sessions = 0i64;

        Ok(SystemStatus {
            app_version: env!("CARGO_PKG_VERSION").to_owned(),
            build_target: std::env::consts::OS.to_owned(),
            database_adapter: adapter.to_owned(),
            database_health: health,
            database_size: size,
            database_location: location,
            uptime,
            library_paths_count,
            download_clients_count,
            indexers_count,
            active_transcodes,
            active_streaming_sessions,
        })
    }

    fn describe_db(db: &DatabaseConnection) -> (&'static str, String) {
        match db.get_database_backend() {
            // Connection-string introspection isn't on sea-orm's public
            // surface; the pool location read is the Phoenix
            // equivalent and we fall back to a stable "configured"
            // label when no path-like info is available.
            DatabaseBackend::Sqlite => ("sqlite", "(configured)".to_owned()),
            DatabaseBackend::Postgres => ("postgres", "(configured)".to_owned()),
            _ => ("unknown", "(configured)".to_owned()),
        }
    }

    async fn probe_db(db: &DatabaseConnection) -> Result<(String, String), ServerFnError> {
        let backend = db.get_database_backend();
        let sql = match backend {
            DatabaseBackend::Sqlite => {
                "SELECT page_count * page_size AS s FROM pragma_page_count(), pragma_page_size()"
            }
            DatabaseBackend::Postgres => "SELECT pg_database_size(current_database())::bigint AS s",
            _ => {
                return Ok(("unknown".to_owned(), "unhealthy".to_owned()));
            }
        };
        let row = db
            .query_one_raw(Statement::from_string(backend, sql.to_owned()))
            .await
            .map_err(|err| ServerFnError::new(format!("db size: {err}")))?;
        let size_bytes = match row {
            Some(r) => r
                .try_get::<i64>("", "s")
                .map_err(|err| ServerFnError::new(format!("db size decode: {err}")))?,
            None => 0,
        };
        Ok((format_bytes(size_bytes), "healthy".to_owned()))
    }

    fn format_bytes(bytes: i64) -> String {
        const KB: f64 = 1024.0;
        const MB: f64 = KB * 1024.0;
        const GB: f64 = MB * 1024.0;
        let b = bytes as f64;
        if b >= GB {
            format!("{:.2} GB", b / GB)
        } else if b >= MB {
            format!("{:.2} MB", b / MB)
        } else if b >= KB {
            format!("{:.2} KB", b / KB)
        } else {
            format!("{bytes} B")
        }
    }

    fn format_uptime(elapsed: std::time::Duration) -> String {
        let seconds = elapsed.as_secs();
        let minutes = seconds / 60;
        let hours = minutes / 60;
        let days = hours / 24;
        if days > 0 {
            format!("{days}d {}h", hours % 24)
        } else if hours > 0 {
            format!("{hours}h {}m", minutes % 60)
        } else if minutes > 0 {
            format!("{minutes}m {}s", seconds % 60)
        } else {
            format!("{seconds}s")
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn format_bytes_picks_units() {
            assert_eq!(format_bytes(0), "0 B");
            assert_eq!(format_bytes(512), "512 B");
            assert_eq!(format_bytes(2048), "2.00 KB");
            assert_eq!(format_bytes(3 * 1024 * 1024), "3.00 MB");
            assert_eq!(format_bytes(2 * 1024 * 1024 * 1024), "2.00 GB");
        }

        #[test]
        fn format_uptime_picks_units() {
            assert_eq!(
                format_uptime(std::time::Duration::from_secs(45)),
                "45s".to_owned()
            );
            assert_eq!(
                format_uptime(std::time::Duration::from_secs(60 * 5 + 3)),
                "5m 3s".to_owned()
            );
            assert_eq!(
                format_uptime(std::time::Duration::from_secs(3600 * 2 + 60 * 7)),
                "2h 7m".to_owned()
            );
            assert_eq!(
                format_uptime(std::time::Duration::from_secs(86_400 * 3 + 3600 * 5)),
                "3d 5h".to_owned()
            );
        }
    }
}
