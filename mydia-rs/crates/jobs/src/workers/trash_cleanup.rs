//! Port of `lib/mydia/jobs/trash_cleanup.ex`.
//!
//! Permanently deletes media files that have been trashed beyond the
//! configured retention period (default 30 days).
//!
//! Post-U12 cutover: SeaORM-native against the `media_files` entity.
//! The cutoff bind threads through `DateTimeSecs::into_simple_expr`.

use apalis::prelude::Data;
use chrono::{Duration, Utc};
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{ColumnTrait, DatabaseConnection, EntityTrait, QueryFilter};
use serde::{Deserialize, Serialize};

use mydia_rs_db::types::DateTimeSecs;
use mydia_rs_entities::media_files;

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

/// Hard-delete `media_files` rows whose `trashed_at` is older than
/// the retention window. Mirrors
/// `Mydia.Library.purge_old_trashed_media_files/1`.
async fn purge_old_trashed_media_files(
    db: &DatabaseConnection,
    retention_days: i64,
) -> Result<u64, JobsError> {
    if retention_days <= 0 {
        return Err(JobsError::WorkerError("retention_days must be > 0".into()));
    }
    let backend = db.get_database_backend();
    let cutoff = DateTimeSecs::from(Utc::now() - Duration::days(retention_days));
    let res = media_files::Entity::delete_many()
        .filter(media_files::Column::TrashedAt.is_not_null())
        .filter(Expr::col(media_files::Column::TrashedAt).lt(cutoff.into_simple_expr(backend)))
        .exec(db)
        .await?;
    Ok(res.rows_affected)
}
