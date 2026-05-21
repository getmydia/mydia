//! Port of `lib/mydia/jobs/trakt_sync.ex`.
//!
//! Orchestrates `history`, `ratings`, `collection`, `watchlist`, and
//! `full` sync passes for a specific user's Trakt integration. The
//! actual sync work lives in [`mydia_rs_integrations::trakt::sync`] —
//! this worker is a thin dispatcher that the parallel-window cutover
//! keeps wire-compatible with Phoenix's Oban job.

use apalis::prelude::Data;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TraktSyncArgs {
    pub user_id: String,
    /// One of `"history"`, `"ratings"`, `"collection"`, `"watchlist"`,
    /// or `"full"`. Mirrors Phoenix's string union exactly.
    pub sync_type: String,
}

pub const QUEUE: Queue = Queue::Integrations;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn trakt_sync(args: TraktSyncArgs, _ctx: Data<AppContext>) -> Result<(), JobsError> {
    let sync_type = args.sync_type.as_str();
    tracing::info!(
        user_id = %args.user_id,
        sync_type,
        "starting Trakt sync"
    );

    match sync_type {
        "full" | "history" | "ratings" | "collection" | "watchlist" => {
            // The full sync flow drives `mydia_rs_integrations::trakt::sync`
            // helpers per sync kind, matching the Phoenix worker. The
            // building-block functions already exist for payload
            // construction; the DB-write half landing here is U17's
            // scope but the deeper sqlx queries (collection upserts,
            // history insertions, ...) are tracked separately —
            // documented as a stub for the cron-driven happy path until
            // the schema layer in U5 exposes the writes.
            //
            // The cron-driven `MediaServerWatchedSync` and the
            // user-triggered call sites both reach this dispatcher;
            // returning Ok keeps the apalis run-loop healthy and the
            // Phoenix Oban shadow continues to do the actual writes
            // during U30's parallel window.
            tracing::warn!(
                user_id = %args.user_id,
                sync_type,
                "trakt sync delegated to Phoenix during cutover window"
            );
            Ok(())
        }
        other => Err(JobsError::WorkerError(format!(
            "Unknown sync type: {other}"
        ))),
    }
}
