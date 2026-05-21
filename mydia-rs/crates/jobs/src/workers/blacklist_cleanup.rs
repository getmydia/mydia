//! Port of `lib/mydia/jobs/blacklist_cleanup.ex`.
//!
//! Periodic worker that purges expired release-blacklist rows (issue
//! #123). Rows whose `expires_at` is in the past are deleted. Rows with
//! `expires_at = NULL` (blocked forever) are left alone.
//!
//! Scheduled daily via the cron entry registered in `cron::schedule()`.

use apalis::prelude::Data;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

/// Cron-driven worker — no caller-supplied args.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BlacklistCleanupArgs {}

/// Queue assignment — matches `use Oban.Worker, queue: :maintenance`.
pub const QUEUE: Queue = Queue::Maintenance;

/// Retry budget — matches `max_attempts: 3`.
pub const MAX_ATTEMPTS: u32 = 3;

/// Sweep expired blacklist entries. Returns `Ok(())` even if zero
/// rows were deleted; this is a maintenance worker and the operator
/// only cares that it ran.
pub async fn blacklist_cleanup(
    _args: BlacklistCleanupArgs,
    ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    let deleted = sweep_expired(&ctx.db).await?;
    tracing::info!(
        deleted_count = deleted,
        "release blacklist cleanup completed"
    );
    Ok(())
}

/// Delete every `download_release_blacklist` row whose `expires_at`
/// is strictly less than `now`. Mirrors
/// `Mydia.Downloads.Blacklists.cleanup_expired/0`.
async fn sweep_expired(db: &mydia_rs_db::Db) -> Result<u64, JobsError> {
    use mydia_rs_db::Db;
    let now = chrono::Utc::now();
    let rows_affected = match db {
        Db::Sqlite(pool) => sqlx::query(
            "DELETE FROM download_release_blacklist \
                 WHERE expires_at IS NOT NULL AND expires_at < ?",
        )
        .bind(now.to_rfc3339())
        .execute(pool)
        .await?
        .rows_affected(),
        Db::Postgres(pool) => sqlx::query(
            "DELETE FROM download_release_blacklist \
                 WHERE expires_at IS NOT NULL AND expires_at < $1",
        )
        .bind(now)
        .execute(pool)
        .await?
        .rows_affected(),
    };
    Ok(rows_affected)
}
