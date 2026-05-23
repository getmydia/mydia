//! Background-jobs server functions.
//!
//! Phoenix counterpart: `MydiaWeb.JobsLive.Index` (history table) +
//! `Mydia.Jobs` context. The Phoenix page surfaces a paginated job
//! history out of the Oban tables plus a list of cron-style worker
//! definitions. On the Rust side U17 owns apalis workers; this module
//! exposes a minimal summary used by the admin Jobs page during the
//! parallel window:
//!
//! - [`worker_summary`] — the static list of workers the supervisor
//!   knows about, paired with their pending queue depth read out of
//!   the active apalis storage.
//! - [`trigger_job`] — manual-enqueue endpoint, mirroring the
//!   Phoenix "Run now" button. Only the `LibraryScanner` worker is
//!   wired for U28; the rest are accepted but no-op until U17
//!   finishes plumbing each worker's args through `WebState`.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// One row on the admin Jobs page.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WorkerRow {
    /// Apalis worker identifier as it appears on the `jobs:status`
    /// topic (`library_scanner`, `transcode`, ...).
    pub worker_id: String,
    /// Human-friendly label for the page (`"Library scanner"`).
    pub label: String,
    /// Current pending count from the apalis storage. `None` when
    /// the worker has no storage handle wired into [`WebState`] yet.
    pub pending: Option<i64>,
    /// `true` when this worker accepts manual triggers from the UI.
    /// Other workers render the Run button as disabled.
    pub triggerable: bool,
}

/// `(workers, generated_at)`. The page renders the list and a small
/// "loaded N seconds ago" hint.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WorkerSummary {
    pub workers: Vec<WorkerRow>,
    pub generated_at: String,
}

#[get("/api/admin/jobs/summary")]
pub async fn worker_summary() -> Result<WorkerSummary, ServerFnError> {
    server::worker_summary().await
}

#[post("/api/admin/jobs/trigger")]
pub async fn trigger_job(worker_id: String) -> Result<(), ServerFnError> {
    server::trigger(worker_id).await
}

#[cfg(feature = "server")]
mod server {
    use super::{WorkerRow, WorkerSummary};
    use crate::server_fns::auth::require_admin_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use mydia_rs_jobs::workers::library_scanner::LibraryScannerArgs;

    async fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context".to_owned()))?;
        ctx.extension::<WebState>().ok_or_else(|| {
            ServerFnError::new(
                "WebState axum extension missing - wire WebState::layer() in build_router()"
                    .to_owned(),
            )
        })
    }

    pub(super) async fn worker_summary() -> Result<WorkerSummary, ServerFnError> {
        let _user_id = require_admin_user_id().await?;
        let mut state = state().await?;

        // U28 wires the only storage that exists on `WebState` today.
        // Additional workers land as their args land on `WebState`.
        let pending_scanner = state
            .library_scanner_storage
            .len()
            .await
            .map_err(|err| ServerFnError::new(format!("apalis len: {err}")))
            .ok();

        let workers = vec![
            WorkerRow {
                worker_id: "library_scanner".to_owned(),
                label: "Library scanner".to_owned(),
                pending: pending_scanner,
                triggerable: true,
            },
            WorkerRow {
                worker_id: "thumbnail_generation".to_owned(),
                label: "Thumbnail generation".to_owned(),
                pending: None,
                triggerable: false,
            },
            WorkerRow {
                worker_id: "import_list_sync".to_owned(),
                label: "Import list sync".to_owned(),
                pending: None,
                triggerable: false,
            },
            WorkerRow {
                worker_id: "metadata_refresh".to_owned(),
                label: "Metadata refresh".to_owned(),
                pending: None,
                triggerable: false,
            },
        ];

        Ok(WorkerSummary {
            workers,
            generated_at: chrono::Utc::now().to_rfc3339(),
        })
    }

    pub(super) async fn trigger(worker_id: String) -> Result<(), ServerFnError> {
        let _user_id = require_admin_user_id().await?;
        let mut state = state().await?;
        match worker_id.as_str() {
            "library_scanner" => {
                state
                    .library_scanner_storage
                    .push(LibraryScannerArgs {
                        library_path_id: None,
                        library_type: None,
                        skip_delay: true,
                    })
                    .await
                    .map_err(|err| ServerFnError::new(format!("enqueue scan: {err}")))?;
                Ok(())
            }
            other => Err(ServerFnError::new(format!(
                "worker {other:?} is not triggerable yet"
            ))),
        }
    }
}
