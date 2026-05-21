//! Port of `lib/mydia/jobs/import_session_cleanup.ex`.
//!
//! Daily sweep that:
//! - Deletes `import_sessions` rows past `expires_at`.
//! - Deletes `import_sessions` rows marked `completed` older than
//!   7 days.

use apalis::prelude::Data;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

/// How many days after `completed_at` a session is purged. Phoenix
/// hardcodes 7; we keep it overridable for tests.
pub const DEFAULT_COMPLETED_RETENTION_DAYS: i64 = 7;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ImportSessionCleanupArgs {
    #[serde(default)]
    pub completed_retention_days: Option<i64>,
}

pub const QUEUE: Queue = Queue::Maintenance;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn import_session_cleanup(
    args: ImportSessionCleanupArgs,
    ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    tracing::info!("starting import session cleanup");

    let completed_retention = args
        .completed_retention_days
        .unwrap_or(DEFAULT_COMPLETED_RETENTION_DAYS);

    let expired = delete_expired_sessions(&ctx.db).await?;
    let completed = delete_old_completed_sessions(&ctx.db, completed_retention).await?;

    tracing::info!(
        expired_deleted = expired,
        completed_deleted = completed,
        "import session cleanup completed"
    );
    Ok(())
}

async fn delete_expired_sessions(db: &mydia_rs_db::Db) -> Result<u64, JobsError> {
    use mydia_rs_db::Db;
    let now = chrono::Utc::now();
    let rows_affected = match db {
        Db::Sqlite(pool) => sqlx::query(
            "DELETE FROM import_sessions WHERE expires_at IS NOT NULL AND expires_at < ?",
        )
        .bind(now.to_rfc3339())
        .execute(pool)
        .await?
        .rows_affected(),
        Db::Postgres(pool) => sqlx::query(
            "DELETE FROM import_sessions WHERE expires_at IS NOT NULL AND expires_at < $1",
        )
        .bind(now)
        .execute(pool)
        .await?
        .rows_affected(),
    };
    Ok(rows_affected)
}

async fn delete_old_completed_sessions(
    db: &mydia_rs_db::Db,
    retention_days: i64,
) -> Result<u64, JobsError> {
    use mydia_rs_db::Db;
    let cutoff = chrono::Utc::now() - chrono::Duration::days(retention_days);
    let rows_affected = match db {
        Db::Sqlite(pool) => sqlx::query(
            "DELETE FROM import_sessions \
             WHERE status = 'completed' AND completed_at IS NOT NULL AND completed_at < ?",
        )
        .bind(cutoff.to_rfc3339())
        .execute(pool)
        .await?
        .rows_affected(),
        Db::Postgres(pool) => sqlx::query(
            "DELETE FROM import_sessions \
             WHERE status = 'completed' AND completed_at IS NOT NULL AND completed_at < $1",
        )
        .bind(cutoff)
        .execute(pool)
        .await?
        .rows_affected(),
    };
    Ok(rows_affected)
}
