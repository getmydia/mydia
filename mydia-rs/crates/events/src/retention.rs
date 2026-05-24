// Opt this module into the disallowed-methods lint so a future patch
// that backslides into runtime `sqlx::query` (instead of the
// compile-time-checked macro) is flagged at clippy time.
#![warn(clippy::disallowed_methods)]

//! Retention sweep: delete events older than the configured threshold.
//!
//! Port of `Mydia.Events.delete_old_events/1`. The Phoenix worker
//! `Mydia.Jobs.EventCleanup` runs this on a cron schedule; the Rust
//! port exposes the function so U17's apalis worker can call it.
//!
//! Tier-(a) portable SQL: byte-equal between engines (sqlx-sqlite
//! accepts `$N` placeholders). The `Postgres` arm is macro-checked
//! against the offline cache; the `SQLite` arm mirrors verbatim.

use chrono::{Duration, Utc};
use mydia_rs_db::types::DateTimeSecs;
use mydia_rs_db::Db;

use crate::persistence::EventsError;

/// Delete every event whose `inserted_at` is strictly before
/// `now - retention_days`. Returns the number of rows deleted.
///
/// Errors if `retention_days <= 0` — mirrors the Phoenix guard.
pub async fn delete_old_events(db: &Db, retention_days: i64) -> Result<u64, EventsError> {
    if retention_days <= 0 {
        return Err(EventsError::Db(sqlx::Error::Configuration(
            "retention_days must be > 0".into(),
        )));
    }
    let cutoff = DateTimeSecs::from(Utc::now() - Duration::days(retention_days));
    match db {
        Db::Sqlite(pool) => {
            // SQLite arm is runtime form (sqlx::query! is single-dialect
            // and our prepare target is Postgres); SQL is byte-equal to
            // the macro-checked Postgres arm.
            #[allow(clippy::disallowed_methods)]
            let result = sqlx::query("DELETE FROM events WHERE inserted_at < $1")
                .bind(cutoff)
                .execute(pool)
                .await?;
            Ok(result.rows_affected())
        }
        Db::Postgres(pool) => {
            let result = sqlx::query!(
                "DELETE FROM events WHERE inserted_at < $1",
                cutoff as DateTimeSecs
            )
            .execute(pool)
            .await?;
            Ok(result.rows_affected())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn rejects_zero_retention() {
        // This test only exercises the validation guard — no DB
        // contact. We construct a no-op pool by setting up an
        // in-memory SQLite via sqlx.
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        let db = Db::Sqlite(pool);
        let err = delete_old_events(&db, 0).await.unwrap_err();
        assert!(matches!(
            err,
            EventsError::Db(sqlx::Error::Configuration(_))
        ));
    }
}
