//! Port of `lib/mydia/jobs/trash_cleanup.ex`.
//!
//! Permanently deletes media files that have been trashed beyond the
//! configured retention period (default 30 days).

use apalis::prelude::Data;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

/// Default retention in days. Mirrors Phoenix's `@default_retention_days 30`.
pub const DEFAULT_RETENTION_DAYS: i64 = 30;

/// Cron-driven worker — no caller-supplied args.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TrashCleanupArgs {
    /// Override the default retention window. Phoenix reads this from
    /// `Application.get_env(:mydia, :trash_retention_days)`; the Rust
    /// port lets a manual UI-triggered run override the value.
    #[serde(default)]
    pub retention_days: Option<i64>,
}

pub const QUEUE: Queue = Queue::Maintenance;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn trash_cleanup(args: TrashCleanupArgs, ctx: Data<AppContext>) -> Result<(), JobsError> {
    let retention_days = args.retention_days.unwrap_or(DEFAULT_RETENTION_DAYS);
    tracing::info!(retention_days, "starting trash cleanup");

    let deleted = purge_old_trashed_media_files(&ctx.db, retention_days).await?;

    tracing::info!(
        retention_days,
        deleted_count = deleted,
        "trash cleanup completed"
    );
    Ok(())
}

/// Hard-delete `media_files` rows whose `deleted_at` is older than
/// the retention window. Mirrors
/// `Mydia.Library.purge_old_trashed_media_files/1`.
async fn purge_old_trashed_media_files(
    db: &mydia_rs_db::Db,
    retention_days: i64,
) -> Result<u64, JobsError> {
    use mydia_rs_db::Db;
    if retention_days <= 0 {
        return Err(JobsError::WorkerError("retention_days must be > 0".into()));
    }
    let cutoff = chrono::Utc::now() - chrono::Duration::days(retention_days);
    let rows_affected = match db {
        Db::Sqlite(pool) => sqlx::query(
            "DELETE FROM media_files \
             WHERE deleted_at IS NOT NULL AND deleted_at < ?",
        )
        .bind(cutoff.to_rfc3339())
        .execute(pool)
        .await?
        .rows_affected(),
        Db::Postgres(pool) => sqlx::query(
            "DELETE FROM media_files \
             WHERE deleted_at IS NOT NULL AND deleted_at < $1",
        )
        .bind(cutoff)
        .execute(pool)
        .await?
        .rows_affected(),
    };
    Ok(rows_affected)
}
