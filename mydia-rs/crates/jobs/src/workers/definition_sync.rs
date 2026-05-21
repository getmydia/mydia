//! Port of `lib/mydia/jobs/definition_sync.ex`.
//!
//! Syncs Cardigann indexer definitions from the Prowlarr/Indexers
//! GitHub repo into the local DB. Daily cron at 03:00 UTC.

use apalis::prelude::Data;
use mydia_rs_indexers::feature_flags::enabled_from_env as cardigann_enabled;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DefinitionSyncArgs {
    /// Limit definitions fetched (useful for testing).
    #[serde(default)]
    pub limit: Option<usize>,
}

pub const QUEUE: Queue = Queue::Maintenance;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn definition_sync(
    args: DefinitionSyncArgs,
    _ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    if !cardigann_enabled() {
        tracing::info!("definition_sync: Cardigann disabled via feature flag; skipping");
        return Ok(());
    }

    tracing::info!(limit = ?args.limit, "starting Cardigann definition sync");

    // The actual fetch + parse + persist flow lives in
    // `mydia_rs_indexers::cardigann::definition_sync` (port underway).
    // The HTTP fetch + YAML parse half is already in the indexers
    // crate; the persistence half writes through the model layer. The
    // worker shape lines up here so the parallel-window cutover
    // observes apalis ticking at the same cadence as Oban.
    tracing::warn!("definition_sync persistence delegated to Phoenix during cutover window");
    Ok(())
}
