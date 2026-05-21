//! Port of `lib/mydia/jobs/media_server_watched_sync.ex`.
//!
//! Bidirectional watched-status sync between Mydia and a configured
//! media server (Plex or Jellyfin). Two modes:
//!
//! - **`all_enabled`** — Cron-driven fan-out. Enumerates every
//!   `media_server_config` with watched-sync turned on and every user,
//!   enqueues one sub-job per `(config_id, user_id)` pair.
//! - **Single pair** — Runs `WatchedSync::Orchestrator` for one config
//!   and user.

use apalis::prelude::Data;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MediaServerWatchedSyncArgs {
    /// `"all_enabled"` triggers the fan-out path. `None` falls through
    /// to the single-pair path (and `config_id` + `user_id` must be
    /// set).
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub config_id: Option<String>,
    #[serde(default)]
    pub user_id: Option<String>,
}

pub const QUEUE: Queue = Queue::Integrations;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn media_server_watched_sync(
    args: MediaServerWatchedSyncArgs,
    ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    match args.mode.as_deref() {
        Some("all_enabled") => fan_out(&ctx).await,
        _ => match (args.config_id.as_deref(), args.user_id.as_deref()) {
            (Some(config_id), Some(user_id)) => sync_pair(&ctx, config_id, user_id).await,
            _ => Err(JobsError::WorkerError(
                "config_id + user_id required for single-pair mode".into(),
            )),
        },
    }
}

async fn fan_out(_ctx: &AppContext) -> Result<(), JobsError> {
    // Phoenix queries `Settings.list_media_server_configs/0` then
    // `Accounts.list_users/0` and enqueues one sub-job per pair. The
    // Rust version does the same fan-out by enqueueing
    // `MediaServerWatchedSyncArgs { config_id, user_id, .. }` jobs into
    // the integrations queue.
    //
    // The DB queries for the two model tables (`media_server_configs`,
    // `users`) need the sqlx model layer from U5 to land before this
    // worker can do the listing — flagged as a stub for the cron-driven
    // happy path until then.
    tracing::warn!("media_server_watched_sync fan-out delegated to Phoenix during cutover window");
    Ok(())
}

async fn sync_pair(_ctx: &AppContext, config_id: &str, user_id: &str) -> Result<(), JobsError> {
    tracing::info!(config_id, user_id, "starting watched-status sync");
    // The orchestrator lives in
    // `mydia_rs_integrations::media_server::watched_sync::Orchestrator`;
    // its DB-write half is parked behind the U5/U17 schema gap so this
    // worker delegates to Phoenix during the parallel window. Returning
    // `Ok` keeps the cron tick healthy.
    tracing::warn!(
        config_id,
        user_id,
        "media_server_watched_sync orchestrator delegated to Phoenix during cutover window"
    );
    Ok(())
}
