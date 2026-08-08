use std::path::Path;

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::SqlitePool;

use crate::{Db, DbError};

/// Opens the database at `path`, creating it if absent, and runs every
/// pending migration.
pub async fn connect(path: &Path) -> Result<Db, DbError> {
    // Prefer filename over a sqlite:// URL so absolute and relative paths
    // both resolve unambiguously (URL forms disagree on slash count).
    let options = SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(true)
        .foreign_keys(true)
        // WAL lets the scan write while the player reads.
        .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal)
        .busy_timeout(std::time::Duration::from_secs(10));

    let pool = SqlitePoolOptions::new()
        .max_connections(8)
        .connect_with(options)
        .await
        .map_err(DbError::Connect)?;

    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .map_err(DbError::Migrate)?;

    Ok(Db { pool })
}

/// Opens a throwaway database in a temporary directory. The returned
/// `TempDir` must be held for the lifetime of the test: dropping it deletes
/// the database file.
pub async fn connect_temp() -> Result<(Db, tempfile::TempDir), DbError> {
    let dir = tempfile::tempdir().map_err(DbError::TempDir)?;
    let db = connect(&dir.path().join("mydia.db")).await?;
    Ok((db, dir))
}

impl Db {
    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }
}

#[cfg(test)]
mod tests {
    use super::connect_temp;

    #[tokio::test]
    async fn migrations_create_the_expected_tables() {
        let (db, _guard) = connect_temp().await.unwrap();

        let names: Vec<String> =
            sqlx::query_scalar("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
                .fetch_all(db.pool())
                .await
                .unwrap();

        assert!(names.contains(&"users".to_string()), "got {names:?}");
        assert!(names.contains(&"devices".to_string()), "got {names:?}");
        assert!(names.contains(&"settings".to_string()), "got {names:?}");
    }

    #[tokio::test]
    async fn foreign_keys_are_enforced() {
        let (db, _guard) = connect_temp().await.unwrap();

        let result = sqlx::query(
            "INSERT INTO devices (id, user_id, device_id, device_name, platform, inserted_at, last_seen_at)
             VALUES ('d1', 'nonexistent-user', 'dev-1', 'Phone', 'android', datetime('now'), datetime('now'))",
        )
        .execute(db.pool())
        .await;

        assert!(
            result.is_err(),
            "insert with a dangling user_id should fail"
        );
    }
}
