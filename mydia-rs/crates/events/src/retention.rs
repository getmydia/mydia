//! Retention sweep: delete events older than the configured threshold.
//!
//! Port of `Mydia.Events.delete_old_events/1`. The Phoenix worker
//! `Mydia.Jobs.EventCleanup` runs this on a cron schedule; the Rust
//! port exposes the function so U17's apalis worker can call it.
//!
//! Post-U8 cutover: SeaORM-native. The bulk DELETE flows through
//! `Entity::delete_many().filter(...).exec(db)`, with the cutoff bound
//! through `DateTimeSecs::into_simple_expr(backend)` so Postgres gets
//! the `::timestamptz` cast on the parameter.

use chrono::{Duration, Utc};
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{DatabaseConnection, DbErr, EntityTrait, QueryFilter};

use mydia_rs_db::types::DateTimeSecs;
use mydia_rs_entities::events;

use crate::persistence::EventsError;

/// Delete every event whose `inserted_at` is strictly before
/// `now - retention_days`. Returns the number of rows deleted.
///
/// Errors if `retention_days <= 0` — mirrors the Phoenix guard.
pub async fn delete_old_events(
    db: &DatabaseConnection,
    retention_days: i64,
) -> Result<u64, EventsError> {
    if retention_days <= 0 {
        return Err(EventsError::Db(DbErr::Custom(
            "retention_days must be > 0".into(),
        )));
    }
    let backend = db.get_database_backend();
    let cutoff = DateTimeSecs::from(Utc::now() - Duration::days(retention_days));

    let result = events::Entity::delete_many()
        .filter(Expr::col(events::Column::InsertedAt).lt(cutoff.into_simple_expr(backend)))
        .exec(db)
        .await?;
    Ok(result.rows_affected)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sea_orm::Database;

    #[tokio::test]
    async fn rejects_zero_retention() {
        // The guard short-circuits before any query is built; an
        // unconfigured in-memory SQLite handle is enough to exercise it.
        let db = Database::connect("sqlite::memory:").await.unwrap();
        let err = delete_old_events(&db, 0).await.unwrap_err();
        assert!(matches!(err, EventsError::Db(DbErr::Custom(_))));
    }
}
