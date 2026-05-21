//! Port of `lib/mydia/jobs/import_list_scheduler.ex`.
//!
//! Cron worker (every 15 minutes) that checks every enabled import
//! list against its `last_sync_at + sync_interval_hours`. For each list
//! due for sync, enqueues an `ImportListSync` job.

use apalis::prelude::Data;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ImportListSchedulerArgs {}

pub const QUEUE: Queue = Queue::ImportLists;
pub const MAX_ATTEMPTS: u32 = 1;

pub async fn import_list_scheduler(
    _args: ImportListSchedulerArgs,
    ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    tracing::info!("checking for import lists due for sync");
    let due = list_sync_due_lists(&ctx.db).await?;
    tracing::info!(count = due.len(), "import lists due for sync");

    // The actual enqueue uses `JobStorage<ImportListSyncArgs>` via the
    // supervisor-injected handle. For U17 we log the work plan; the
    // supervision tree in `crate::supervisor` will register a per-type
    // storage that this worker can push into once the storage handles
    // are surfaced as `Data` extractors.
    for id in &due {
        tracing::debug!(import_list_id = %id, "would enqueue ImportListSync");
    }
    tracing::warn!(
        count = due.len(),
        "import_list_scheduler enqueue delegated to Phoenix during cutover window"
    );
    Ok(())
}

async fn list_sync_due_lists(db: &mydia_rs_db::Db) -> Result<Vec<String>, JobsError> {
    use mydia_rs_db::Db;
    let now = chrono::Utc::now();
    // Rough port: enabled lists whose `last_sync_at + sync_interval_hours`
    // is in the past, plus lists never synced.
    let rows: Vec<(String,)> = match db {
        Db::Sqlite(pool) => {
            sqlx::query_as(
                "SELECT id FROM import_lists \
             WHERE enabled = 1 \
             AND (last_sync_at IS NULL OR \
                  datetime(last_sync_at, '+' || sync_interval_hours || ' hours') < ?) \
             ORDER BY inserted_at ASC",
            )
            .bind(now.to_rfc3339())
            .fetch_all(pool)
            .await?
        }
        Db::Postgres(pool) => {
            sqlx::query_as(
                "SELECT id FROM import_lists \
             WHERE enabled = true \
             AND (last_sync_at IS NULL OR \
                  last_sync_at + (sync_interval_hours * INTERVAL '1 hour') < $1) \
             ORDER BY inserted_at ASC",
            )
            .bind(now)
            .fetch_all(pool)
            .await?
        }
    };
    Ok(rows.into_iter().map(|(id,)| id).collect())
}
