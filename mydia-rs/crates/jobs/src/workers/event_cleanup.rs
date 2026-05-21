//! Port of `lib/mydia/jobs/event_cleanup.ex`.
//!
//! Weekly retention sweep over the `events` table. Delegates to
//! [`mydia_rs_events::retention::delete_old_events`], which mirrors the
//! Phoenix `Mydia.Events.delete_old_events/1` shape.

use apalis::prelude::Data;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

/// Default retention in days. Mirrors Phoenix's `@default_retention_days 90`.
pub const DEFAULT_RETENTION_DAYS: i64 = 90;

/// Cron-driven worker. Args carry an optional override on the retention
/// window — same shape Phoenix reads from `Application.get_env`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct EventCleanupArgs {
    #[serde(default)]
    pub retention_days: Option<i64>,
}

pub const QUEUE: Queue = Queue::Maintenance;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn event_cleanup(args: EventCleanupArgs, ctx: Data<AppContext>) -> Result<(), JobsError> {
    let retention_days = args.retention_days.unwrap_or(DEFAULT_RETENTION_DAYS);
    tracing::info!(retention_days, "starting event cleanup");

    let deleted = mydia_rs_events::retention::delete_old_events(&ctx.db, retention_days)
        .await
        .map_err(|err| JobsError::WorkerError(err.to_string()))?;

    tracing::info!(
        retention_days,
        deleted_count = deleted,
        "event cleanup completed"
    );
    Ok(())
}
