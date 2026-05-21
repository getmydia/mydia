//! Port of `lib/mydia/jobs/cardigann_health_check.ex`.
//!
//! Runs hourly to test connections and update health status for every
//! enabled Cardigann indexer. The actual probe lives in
//! [`mydia_rs_indexers::health`] / per-adapter `test_connection`; this
//! worker fans out across the registry.

use apalis::prelude::Data;
use mydia_rs_indexers::feature_flags::enabled_from_env as cardigann_enabled;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CardigannHealthCheckArgs {
    /// Probe a single definition. None = probe every enabled indexer.
    #[serde(default)]
    pub definition_id: Option<String>,
}

pub const QUEUE: Queue = Queue::Maintenance;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn cardigann_health_check(
    args: CardigannHealthCheckArgs,
    ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    if !cardigann_enabled() {
        tracing::debug!("cardigann_health_check: Cardigann disabled; skipping");
        return Ok(());
    }

    if let Some(id) = args.definition_id.as_deref() {
        tracing::info!(definition_id = id, "running single Cardigann health check");
        probe_one(&ctx, id).await
    } else {
        tracing::info!("running all Cardigann health checks");
        probe_all(&ctx).await
    }
}

async fn probe_one(ctx: &AppContext, definition_id: &str) -> Result<(), JobsError> {
    // The adapter lookup uses `ctx.indexers.config(definition_id)` —
    // when the registry is populated by the boot path. The probe call
    // is `adapter.test_connection(...)`.
    if ctx.indexers.config(definition_id).is_some() {
        tracing::warn!(
            definition_id,
            "cardigann_health_check probe delegated to Phoenix during cutover window"
        );
    } else {
        tracing::debug!(definition_id, "no indexer config registered for definition");
    }
    Ok(())
}

async fn probe_all(ctx: &AppContext) -> Result<(), JobsError> {
    let configs = ctx.indexers.list_configs();
    tracing::info!(count = configs.len(), "probing Cardigann indexers");
    for cfg in &configs {
        tracing::debug!(id = %cfg.id, "would probe");
    }
    if !configs.is_empty() {
        tracing::warn!(
            count = configs.len(),
            "cardigann_health_check probes delegated to Phoenix during cutover window"
        );
    }
    Ok(())
}
