//! Port of `lib/mydia/jobs/import_list_scheduler.ex`.
//!
//! Cron worker (every 15 minutes) that checks every enabled import
//! list against its `last_synced_at + sync_interval`. For each list
//! due for sync, enqueues an `ImportListSync` job.
//!
//! Post-U12 cutover: SeaORM-native against `import_lists`. The
//! dialect-specific date arithmetic that the prior raw-SQL path used
//! (`datetime(last_sync_at, '+N hours')` on SQLite vs.
//! `last_sync_at + INTERVAL '1 hour'` on Postgres) collapses to a
//! single Rust-side filter: fetch enabled rows, decide due-ness in
//! Rust. Volume is low (handful of import lists per instance) so the
//! engine-side filter buys nothing here.

use apalis::prelude::Data;
use chrono::{Duration, Utc};
use sea_orm::{ColumnTrait, EntityTrait, QueryFilter, QueryOrder};
use serde::{Deserialize, Serialize};

use mydia_rs_db::types::UuidText;
use mydia_rs_db::DatabaseConnection;
use mydia_rs_entities::import_lists;

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
    // supervisor-injected handle. For the cutover window we log the
    // work plan; the supervision tree in `crate::supervisor` will
    // register a per-type storage that this worker can push into once
    // the storage handles are surfaced as `Data` extractors.
    for id in &due {
        tracing::debug!(import_list_id = %id, "would enqueue ImportListSync");
    }
    tracing::warn!(
        count = due.len(),
        "import_list_scheduler enqueue delegated to Phoenix during cutover window"
    );
    Ok(())
}

async fn list_sync_due_lists(db: &DatabaseConnection) -> Result<Vec<UuidText>, JobsError> {
    let now = Utc::now();
    // Fetch every enabled list and decide due-ness in Rust. Phoenix
    // stores `sync_interval` as hours (i32); a list is due when
    // `last_synced_at + sync_interval hours < now`, OR when it was
    // never synced.
    let rows = import_lists::Entity::find()
        .filter(import_lists::Column::Enabled.eq(true))
        .order_by_asc(import_lists::Column::InsertedAt)
        .all(db)
        .await?;
    let mut due = Vec::new();
    for row in rows {
        let is_due = match row.last_synced_at {
            None => true,
            Some(last) => {
                let next = last.0 + Duration::hours(i64::from(row.sync_interval));
                next < now
            }
        };
        if is_due {
            due.push(row.id);
        }
    }
    Ok(due)
}
