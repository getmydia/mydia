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

    #[tokio::test]
    async fn the_library_migration_creates_its_tables() {
        let (db, _guard) = connect_temp().await.unwrap();

        let names: Vec<String> =
            sqlx::query_scalar("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
                .fetch_all(db.pool())
                .await
                .unwrap();

        for expected in [
            "library_paths",
            "media_items",
            "episodes",
            "media_files",
            "scan_runs",
            "scan_issues",
        ] {
            assert!(
                names.contains(&expected.to_string()),
                "missing {expected}, got {names:?}"
            );
        }
    }

    #[tokio::test]
    async fn a_media_file_must_belong_to_exactly_one_owner() {
        let (db, _guard) = connect_temp().await.unwrap();

        let orphan = sqlx::query(
            "INSERT INTO media_files (id, path, mtime, scanned_at)
             VALUES ('f1', '/a.mkv', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        )
        .execute(db.pool())
        .await;

        assert!(orphan.is_err(), "a file with no owner should be rejected");
    }

    #[tokio::test]
    async fn deleting_a_library_path_removes_its_items() {
        let (db, _guard) = connect_temp().await.unwrap();

        sqlx::query(
            "INSERT INTO library_paths (id, path, library_type, inserted_at, updated_at)
             VALUES ('lp1', '/media/movies', 'movies',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        )
        .execute(db.pool())
        .await
        .unwrap();

        sqlx::query(
            "INSERT INTO media_items
               (id, library_path_id, media_type, title, identity_key, added_at, updated_at)
             VALUES ('m1', 'lp1', 'movie', 'The Matrix', 'thematrix',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        )
        .execute(db.pool())
        .await
        .unwrap();

        sqlx::query("DELETE FROM library_paths WHERE id = 'lp1'")
            .execute(db.pool())
            .await
            .unwrap();

        let remaining: i64 = sqlx::query_scalar("SELECT count(*) FROM media_items")
            .fetch_one(db.pool())
            .await
            .unwrap();

        assert_eq!(remaining, 0);
    }

    #[tokio::test]
    async fn two_items_with_the_same_title_and_no_year_collide() {
        let (db, _guard) = connect_temp().await.unwrap();

        sqlx::query(
            "INSERT INTO library_paths (id, path, library_type, inserted_at, updated_at)
             VALUES ('lp1', '/media/tv', 'series',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        )
        .execute(db.pool())
        .await
        .unwrap();

        let insert = |id: &'static str| {
            sqlx::query(
                "INSERT INTO media_items
                   (id, library_path_id, media_type, title, identity_key, added_at, updated_at)
                 VALUES (?, 'lp1', 'tv_show', 'Show', 'show',
                         '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            )
            .bind(id)
            .execute(db.pool())
        };

        insert("s1").await.unwrap();

        // SQLite treats NULLs as distinct in a UNIQUE index, so the index has
        // to fold a missing year into a sentinel or every rescan would insert
        // a second row for every show whose filename carries no year.
        assert!(insert("s2").await.is_err());
    }
}
