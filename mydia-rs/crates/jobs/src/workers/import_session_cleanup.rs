//! Port of `lib/mydia/jobs/import_session_cleanup.ex`.
//!
//! Daily sweep that:
//! - Deletes `import_sessions` rows past `expires_at`.
//! - Deletes `import_sessions` rows marked `completed` older than
//!   7 days.
//!
//! Post-U12 cutover: SeaORM-native against `import_sessions`.

use apalis::prelude::Data;
use chrono::{Duration, Utc};
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{ColumnTrait, DatabaseConnection, EntityTrait, QueryFilter};
use serde::{Deserialize, Serialize};

use mydia_rs_db::types::DateTimeSecs;
use mydia_rs_entities::import_sessions;

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

async fn delete_expired_sessions(db: &DatabaseConnection) -> Result<u64, JobsError> {
    let backend = db.get_database_backend();
    let now = DateTimeSecs::from(Utc::now());
    let res = import_sessions::Entity::delete_many()
        .filter(import_sessions::Column::ExpiresAt.is_not_null())
        .filter(Expr::col(import_sessions::Column::ExpiresAt).lt(now.into_simple_expr(backend)))
        .exec(db)
        .await?;
    Ok(res.rows_affected)
}

async fn delete_old_completed_sessions(
    db: &DatabaseConnection,
    retention_days: i64,
) -> Result<u64, JobsError> {
    let backend = db.get_database_backend();
    let cutoff = DateTimeSecs::from(Utc::now() - Duration::days(retention_days));
    let res = import_sessions::Entity::delete_many()
        .filter(import_sessions::Column::Status.eq("completed"))
        .filter(import_sessions::Column::CompletedAt.is_not_null())
        .filter(
            Expr::col(import_sessions::Column::CompletedAt).lt(cutoff.into_simple_expr(backend)),
        )
        .exec(db)
        .await?;
    Ok(res.rows_affected)
}
