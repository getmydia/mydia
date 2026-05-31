//! Port of `lib/mydia/jobs/download_monitor.ex` (~636 LOC in Phoenix).
//!
//! Polls every configured download client every 2 minutes for state
//! changes. Marks downloads completed, enqueues `MediaImport`,
//! records errors, and flags downloads removed manually from the client
//! as `missing` so they show up in the Issues tab.

use std::sync::Arc;
use std::time::Duration;

use apalis::prelude::Data;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::{JobStorage, JobsError};
use crate::workers::media_import::MediaImportArgs;

/// Default grace window for a download whose client config can't be
/// resolved. Mirrors Phoenix's `@default_grace_minutes 60`.
pub const DEFAULT_GRACE_MINUTES: i64 = 60;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DownloadMonitorArgs {
    /// `true` means this tick was self-scheduled by the previous tick
    /// (the "fast follow-up" chain). The follow-up loop self-terminates
    /// once no active downloads remain.
    #[serde(default)]
    pub fast_followup: bool,
}

pub const QUEUE: Queue = Queue::Default;
pub const MAX_ATTEMPTS: u32 = 5;

pub async fn download_monitor(
    args: DownloadMonitorArgs,
    ctx: Data<AppContext>,
    _import_storage: Data<Arc<tokio::sync::Mutex<JobStorage<MediaImportArgs>>>>,
) -> Result<(), JobsError> {
    let start = std::time::Instant::now();
    tracing::info!(
        fast_followup = args.fast_followup,
        "starting download completion monitoring"
    );

    // The full poll flow:
    //   1. List every `downloads` row in non-terminal state.
    //   2. Group by client config, fan-out to each client's
    //      `list_active` / `get_files`.
    //   3. Reconcile against the DB: mark completed, enqueue
    //      MediaImport for any that crossed the completion line.
    //   4. Detect "missing" downloads (in DB, not in client) and tag
    //      them as missing after the per-client grace window.
    //   5. Run `StallDetector` to flag stalled torrents.
    //   6. Run `UntrackedMatcher` to bind orphan torrents to media
    //      items.
    //
    // The poll-active surface of every client is in
    // `mydia_rs_downloads::ClientRegistry::for_protocol`; the row
    // writes wait on the U5 model layer.
    //
    // We exercise the registry shape here so wire-up bugs surface
    // early — `ctx.downloads.is_empty()` returns the same shape an
    // operator would see if no clients are configured yet.
    if ctx.downloads.is_empty() {
        tracing::info!("no download clients configured; skipping monitor sweep");
        return Ok(());
    }

    tracing::warn!("download_monitor reconciliation delegated to Phoenix during cutover window");

    let elapsed_ms = start.elapsed().as_millis();
    tracing::info!(duration_ms = elapsed_ms, "download monitor pass complete");

    // The fast-followup chain isn't wired in U17 (it requires the
    // U17 storage push from inside the worker, which we'll wire once
    // the apalis Data<JobStorage<...>> extractor is shaped); ignore
    // the chain for the parallel window — cron at 2-minute cadence
    // continues to drive ticks.
    let _ = Duration::from_secs(15);
    Ok(())
}
