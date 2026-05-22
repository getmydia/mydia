//! Library-paths CRUD + trigger-scan server functions.
//!
//! Port of the server-side write surface from
//! `MydiaWeb.AdminLibraryPathsLive.Index`'s `handle_event/3` clauses:
//! list, create (validation includes a filesystem readability probe),
//! delete, trigger scan via apalis.
//!
//! No update/edit endpoint at U23 — the Phoenix `LiveView` supports it
//! but the deliberate fitness-probe scope keeps the surface tight and
//! the `LiveView` edit-form pattern is already covered by U22's core
//! components. Add when the page promotes from pilot to general
//! admin use.
//!
//! ## Dual-target shape
//!
//! Dioxus 0.7's `#[get]` / `#[post]` macros expand each function into
//! a client-side HTTP fetch when the `server` feature is OFF and into
//! the user-written body when it's ON. That means the wire-payload
//! types live at module top level (compile for both wasm and server),
//! while the actual sqlx / pubsub / apalis calls go inside a
//! [`server`]-gated helper module so the wasm hydration build never
//! tries to resolve those imports.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// One row from the `library_paths` table, in the shape the page
/// needs. Mirrors `Mydia.Settings.LibraryPath` field-for-field for the
/// columns the admin index actually reads.
///
/// Dual-target: serialized over the wire on both directions of the
/// server-fn call, so the page component (wasm) and the handler
/// (native server) reference the same struct.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LibraryPathRow {
    pub id: String,
    pub path: String,
    /// `:movies` / `:series` / `:music` / `:books` / `:adult` — bare
    /// strings so the page renders without an enum dependency.
    #[serde(rename = "type")]
    pub kind: String,
    pub monitored: bool,
    /// `nil` / `pending` / `in_progress` / `completed` / `failed`.
    /// Optional because runtime paths (USB mounts etc.) never write.
    #[serde(default)]
    pub last_scan_status: Option<String>,
    #[serde(default)]
    pub last_scan_error: Option<String>,
    #[serde(default)]
    pub last_scan_at: Option<String>,
}

/// Form payload for "add a library path."
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct NewLibraryPath {
    pub path: String,
    /// Bare string; the server validates it against the small enum
    /// set the schema accepts.
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default = "default_monitored")]
    pub monitored: bool,
}

const fn default_monitored() -> bool {
    true
}

/// Result of triggering a scan. The `task_id` is useful for the
/// page's optimistic UI state, even though the realtime channel
/// drives the actual progress.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TriggerScanAck {
    pub task_id: String,
    pub library_path_id: String,
}

// ---------- server fns at module top level so the macro can emit both
//            the client-side wrapper and the server-side handler ----------

/// List every library path, ordered by `inserted_at` ASC.
#[get("/api/admin/library_paths")]
pub async fn list_library_paths() -> Result<Vec<LibraryPathRow>, ServerFnError> {
    server::list().await
}

/// Validate and insert a new `library_paths` row.
///
/// Mirrors the Phoenix validator chain:
/// 1. `path` non-blank, `kind` in the small enum set.
/// 2. Directory exists, is a directory, and is readable.
/// 3. Insert; UNIQUE constraint on `path` surfaces as a validation
///    message, not a generic 500.
#[post("/api/admin/library_paths")]
pub async fn create_library_path(
    new_path: NewLibraryPath,
) -> Result<LibraryPathRow, ServerFnError> {
    server::create(new_path).await
}

/// Delete a `library_paths` row by ID.
#[post("/api/admin/library_paths/delete")]
pub async fn delete_library_path(id: String) -> Result<(), ServerFnError> {
    server::delete(id).await
}

/// Enqueue a scan job for a specific library path. Returns the
/// apalis `task_id` so the caller can correlate with the realtime
/// scan-progress stream.
#[post("/api/admin/library_paths/scan")]
pub async fn trigger_scan(id: String) -> Result<TriggerScanAck, ServerFnError> {
    server::trigger_scan(id).await
}

// ---------- server-only implementation ----------

#[cfg(feature = "server")]
mod server {
    use super::{LibraryPathRow, NewLibraryPath, TriggerScanAck};
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use mydia_rs_db::Db;
    use mydia_rs_jobs::workers::library_scanner::LibraryScannerArgs;
    use std::path::PathBuf;

    /// Library types valid for `library_paths.type` — mirror of the
    /// Phoenix Ecto enum on `Mydia.Settings.LibraryPath`.
    const VALID_KINDS: &[&str] = &[
        "movies",
        "series",
        "music",
        "books",
        "adult",
        "music_videos",
    ];

    pub(super) async fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current().ok_or_else(|| {
            ServerFnError::new("no fullstack context (server fn outside request?)".to_owned())
        })?;
        ctx.extension::<WebState>().ok_or_else(|| {
            ServerFnError::new(
                "WebState axum extension missing — attach via `.layer(Extension(WebState))`."
                    .to_owned(),
            )
        })
    }

    type LibraryPathTuple = (
        String,
        String,
        String,
        bool,
        Option<String>,
        Option<String>,
        Option<chrono::DateTime<chrono::Utc>>,
    );

    pub(super) async fn list() -> Result<Vec<LibraryPathRow>, ServerFnError> {
        let state = state().await?;
        let rows: Vec<LibraryPathTuple> = match &state.db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT id, path, type, monitored, last_scan_status, last_scan_error, last_scan_at \
                 FROM library_paths \
                 ORDER BY inserted_at ASC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query library_paths: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT id, path, type, monitored, last_scan_status, last_scan_error, last_scan_at \
                 FROM library_paths \
                 ORDER BY inserted_at ASC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query library_paths: {err}")))?,
        };

        Ok(rows
            .into_iter()
            .map(
                |(id, path, kind, monitored, last_scan_status, last_scan_error, last_scan_at)| {
                    LibraryPathRow {
                        id,
                        path,
                        kind,
                        monitored,
                        last_scan_status,
                        last_scan_error,
                        last_scan_at: last_scan_at.map(|dt| dt.to_rfc3339()),
                    }
                },
            )
            .collect())
    }

    pub(super) async fn create(new_path: NewLibraryPath) -> Result<LibraryPathRow, ServerFnError> {
        if new_path.path.trim().is_empty() {
            return Err(ServerFnError::new("path cannot be blank".to_owned()));
        }
        if !VALID_KINDS.contains(&new_path.kind.as_str()) {
            return Err(ServerFnError::new(format!(
                "invalid library type {:?}; must be one of {VALID_KINDS:?}",
                new_path.kind
            )));
        }
        validate_directory(&new_path.path)?;

        let state = state().await?;
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now();

        match &state.db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "INSERT INTO library_paths (id, path, type, monitored, inserted_at, updated_at) \
                     VALUES (?, ?, ?, ?, ?, ?)",
                )
                .bind(&id)
                .bind(&new_path.path)
                .bind(&new_path.kind)
                .bind(new_path.monitored)
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert library_path: {err}")))?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "INSERT INTO library_paths (id, path, type, monitored, inserted_at, updated_at) \
                     VALUES ($1, $2, $3, $4, $5, $6)",
                )
                .bind(&id)
                .bind(&new_path.path)
                .bind(&new_path.kind)
                .bind(new_path.monitored)
                .bind(now)
                .bind(now)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert library_path: {err}")))?;
            }
        }

        Ok(LibraryPathRow {
            id,
            path: new_path.path,
            kind: new_path.kind,
            monitored: new_path.monitored,
            last_scan_status: None,
            last_scan_error: None,
            last_scan_at: None,
        })
    }

    pub(super) async fn delete(id: String) -> Result<(), ServerFnError> {
        let state = state().await?;
        let affected = match &state.db {
            Db::Sqlite(pool) => sqlx::query("DELETE FROM library_paths WHERE id = ?")
                .bind(&id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("delete library_path: {err}")))?
                .rows_affected(),
            Db::Postgres(pool) => sqlx::query("DELETE FROM library_paths WHERE id = $1")
                .bind(&id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("delete library_path: {err}")))?
                .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!("no library_path with id {id}")));
        }
        Ok(())
    }

    pub(super) async fn trigger_scan(id: String) -> Result<TriggerScanAck, ServerFnError> {
        let mut state = state().await?;
        let exists: Option<(String,)> = match &state.db {
            Db::Sqlite(pool) => sqlx::query_as("SELECT id FROM library_paths WHERE id = ?")
                .bind(&id)
                .fetch_optional(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("query library_path: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as("SELECT id FROM library_paths WHERE id = $1")
                .bind(&id)
                .fetch_optional(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("query library_path: {err}")))?,
        };
        if exists.is_none() {
            return Err(ServerFnError::new(format!("no library_path with id {id}")));
        }

        let task_id = state
            .library_scanner_storage
            .push(LibraryScannerArgs {
                library_path_id: Some(id.clone()),
                library_type: None,
                skip_delay: true,
            })
            .await
            .map_err(|err| ServerFnError::new(format!("enqueue scan: {err}")))?;

        Ok(TriggerScanAck {
            task_id,
            library_path_id: id,
        })
    }

    /// Filesystem readability probe matching Phoenix's
    /// `validate_directory/1`.
    fn validate_directory(path: &str) -> Result<(), ServerFnError> {
        let trimmed = path.trim();
        if trimmed.is_empty() {
            return Err(ServerFnError::new("path cannot be blank".to_owned()));
        }
        let pb = PathBuf::from(trimmed);
        match std::fs::metadata(&pb) {
            Ok(meta) if !meta.is_dir() => {
                Err(ServerFnError::new("path is not a directory".to_owned()))
            }
            Ok(_) => match std::fs::read_dir(&pb) {
                Ok(_) => Ok(()),
                Err(err) if err.kind() == std::io::ErrorKind::PermissionDenied => {
                    Err(ServerFnError::new(
                        "directory is not accessible (permission denied)".to_owned(),
                    ))
                }
                Err(err) => Err(ServerFnError::new(format!("cannot read directory: {err}"))),
            },
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                Err(ServerFnError::new("directory does not exist".to_owned()))
            }
            Err(err) => Err(ServerFnError::new(format!("directory probe failed: {err}"))),
        }
    }
}

// On the wasm target the macro substitutes each fn's body with an
// HTTP fetch — the `server::xxx().await` calls in the user-written
// body are placed inside `#[cfg(feature = "server")]` by the macro,
// so the wasm build never resolves them. No stub module needed.
