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
    use mydia_rs_db::Db;
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

        let library_paths_count = count_rows(&st.db, "library_paths").await.unwrap_or(0);
        let download_clients_count = count_rows(&st.db, "download_clients").await.unwrap_or(0);
        let indexers_count = count_rows(&st.db, "indexers").await.unwrap_or(0);
        let active_transcodes = count_rows_where(
            &st.db,
            "transcode_jobs",
            "status IN ('pending', 'transcoding', 'playing')",
        )
        .await
        .unwrap_or(0);
        let active_streaming_sessions =
            count_rows_where(&st.db, "streaming_sessions", "ended_at IS NULL")
                .await
                .unwrap_or(0);

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

    fn describe_db(db: &Db) -> (&'static str, String) {
        match db {
            // Connection-string introspection isn't on sqlx's public
            // surface; the pool location read is the Phoenix
            // equivalent and we fall back to a stable "configured"
            // label when no path-like info is available.
            Db::Sqlite(_) => ("sqlite", "(configured)".to_owned()),
            Db::Postgres(_) => ("postgres", "(configured)".to_owned()),
        }
    }

    async fn probe_db(db: &Db) -> Result<(String, String), ServerFnError> {
        match db {
            Db::Sqlite(pool) => {
                let (size_bytes,): (i64,) = sqlx::query_as(
                    "SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()",
                )
                .fetch_one(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("sqlite size: {err}")))?;
                Ok((format_bytes(size_bytes), "healthy".to_owned()))
            }
            Db::Postgres(pool) => {
                let (size_bytes,): (i64,) =
                    sqlx::query_as("SELECT pg_database_size(current_database())::bigint")
                        .fetch_one(pool)
                        .await
                        .map_err(|err| ServerFnError::new(format!("postgres size: {err}")))?;
                Ok((format_bytes(size_bytes), "healthy".to_owned()))
            }
        }
    }

    async fn count_rows(db: &Db, table: &str) -> Result<i64, ServerFnError> {
        // `table` is a hard-coded string from this module's call
        // sites; bind-parameter substitution doesn't apply to
        // identifiers anyway. Caller controls the identifier so
        // injection isn't a concern here.
        let query = format!("SELECT COUNT(*) FROM {table}");
        let (n,): (i64,) = match db {
            Db::Sqlite(pool) => sqlx::query_as(&query).fetch_one(pool).await,
            Db::Postgres(pool) => sqlx::query_as(&query).fetch_one(pool).await,
        }
        .map_err(|err| ServerFnError::new(format!("count {table}: {err}")))?;
        Ok(n)
    }

    async fn count_rows_where(db: &Db, table: &str, predicate: &str) -> Result<i64, ServerFnError> {
        let query = format!("SELECT COUNT(*) FROM {table} WHERE {predicate}");
        let (n,): (i64,) = match db {
            Db::Sqlite(pool) => sqlx::query_as(&query).fetch_one(pool).await,
            Db::Postgres(pool) => sqlx::query_as(&query).fetch_one(pool).await,
        }
        .map_err(|err| ServerFnError::new(format!("count {table}: {err}")))?;
        Ok(n)
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
