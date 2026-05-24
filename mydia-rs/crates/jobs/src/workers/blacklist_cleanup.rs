//! Port of `lib/mydia/jobs/blacklist_cleanup.ex`.
//!
//! Periodic worker that purges expired release-blacklist rows (issue
//! #123). Rows whose `expires_at` is in the past are deleted. Rows with
//! `expires_at = NULL` (blocked forever) are left alone.
//!
//! Scheduled daily via the cron entry registered in `cron::schedule()`.
//!
//! Post-U12 cutover: SeaORM-native against the `release_blacklist`
//! entity. The dialect-specific `expires_at < ?` predicate routes
//! through the `DateTimeSecs` wrapper via
//! `into_simple_expr(backend)`, so the Postgres `$N::timestamptz`
//! cast is applied automatically.

use apalis::prelude::Data;
use chrono::Utc;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{ColumnTrait, DatabaseConnection, EntityTrait, QueryFilter};
use serde::{Deserialize, Serialize};

use mydia_rs_db::types::DateTimeSecs;
use mydia_rs_entities::release_blacklist;

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

/// Delete every `release_blacklist` row whose `expires_at` is
/// strictly less than `now`. Mirrors
/// `Mydia.Downloads.Blacklists.cleanup_expired/0`.
async fn sweep_expired(db: &DatabaseConnection) -> Result<u64, JobsError> {
    let backend = db.get_database_backend();
    let now = DateTimeSecs::from(Utc::now());
    let res = release_blacklist::Entity::delete_many()
        .filter(release_blacklist::Column::ExpiresAt.is_not_null())
        .filter(
            Expr::col(release_blacklist::Column::ExpiresAt).lt(now.into_simple_expr(backend)),
        )
        .exec(db)
        .await?;
    Ok(res.rows_affected)
}
