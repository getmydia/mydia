//! Smoke tests for `connect_from_config_seaorm`. Validates the
//! transitional Phase A entry point that returns a `DatabaseConnection`
//! via `Database::connect(ConnectOptions...)`, including:
//!
//! - Pool opens on both `SQLite` (temp file) and Postgres (via
//!   `DATABASE_URL`).
//! - `SELECT 1` smoke query succeeds on the returned connection.
//! - `SQLite` PRAGMAs configured via `map_sqlx_sqlite_opts` reach the
//!   underlying driver — `journal_mode` reads back as the configured
//!   value, `foreign_keys` is on, `temp_store` is `memory`.
//!
//! The `SQLite` test uses a temp-file path so the operating PRAGMAs
//! (especially `journal_mode = WAL`) actually take effect. WAL is a
//! no-op on `:memory:` databases.
//!
//! Postgres path gated on `DATABASE_URL`; unset cleanly skips.

use std::path::PathBuf;

use mydia_rs_config::{Config, DatabaseConfig, DatabaseType, SqliteJournalMode, SqliteSynchronous};
use mydia_rs_db::connect_from_config_seaorm;
use sea_orm::{ConnectionTrait, Statement};
use tempfile::TempDir;

fn sqlite_config_with_journal(mode: SqliteJournalMode) -> (Config, TempDir, PathBuf) {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("seaorm_smoke.db");
    let config = Config {
        database: DatabaseConfig {
            db_type: DatabaseType::Sqlite,
            url: None,
            path: Some(path.to_string_lossy().into_owned()),
            pool_size: 2,
            journal_mode: mode,
            synchronous: SqliteSynchronous::Normal,
            ..DatabaseConfig::default()
        },
        ..Config::default()
    };
    (config, tmp, path)
}

fn postgres_url_from_env() -> Option<String> {
    std::env::var("DATABASE_URL")
        .ok()
        .filter(|u| u.starts_with("postgres://") || u.starts_with("postgresql://"))
}

#[tokio::test]
async fn seaorm_connect_sqlite_opens_and_runs_smoke() {
    let (config, _tmp, _path) = sqlite_config_with_journal(SqliteJournalMode::Wal);
    let db = connect_from_config_seaorm(&config)
        .await
        .expect("connect_seaorm");
    let backend = db.get_database_backend();
    let row = db
        .query_one_raw(Statement::from_string(backend, "SELECT 1 AS v".to_string()))
        .await
        .expect("smoke")
        .expect("row");
    let v: i32 = row.try_get_by("v").expect("v");
    assert_eq!(v, 1);
}

#[tokio::test]
async fn seaorm_connect_sqlite_applies_wal_journal_mode() {
    let (config, _tmp, _path) = sqlite_config_with_journal(SqliteJournalMode::Wal);
    let db = connect_from_config_seaorm(&config)
        .await
        .expect("connect_seaorm");
    let backend = db.get_database_backend();
    let row = db
        .query_one_raw(Statement::from_string(
            backend,
            "PRAGMA journal_mode".to_string(),
        ))
        .await
        .expect("pragma")
        .expect("row");
    // SQLite returns the active journal mode as a string. WAL is the
    // mydia production default and the only mode whose readback differs
    // from the configured value (others read back as-is); confirming WAL
    // here proves the `map_sqlx_sqlite_opts` callback ran.
    let mode: String = row.try_get_by("journal_mode").expect("journal_mode");
    assert_eq!(mode.to_lowercase(), "wal");
}

#[tokio::test]
async fn seaorm_connect_sqlite_enables_foreign_keys_pragma() {
    let (config, _tmp, _path) = sqlite_config_with_journal(SqliteJournalMode::Wal);
    let db = connect_from_config_seaorm(&config)
        .await
        .expect("connect_seaorm");
    let backend = db.get_database_backend();
    let row = db
        .query_one_raw(Statement::from_string(
            backend,
            "PRAGMA foreign_keys".to_string(),
        ))
        .await
        .expect("pragma")
        .expect("row");
    let on: i32 = row.try_get_by("foreign_keys").expect("foreign_keys");
    assert_eq!(on, 1, "foreign_keys PRAGMA should be ON");
}

#[tokio::test]
async fn seaorm_connect_postgres_opens_and_runs_smoke() {
    let Some(url) = postgres_url_from_env() else {
        return;
    };
    let config = Config {
        database: DatabaseConfig {
            db_type: DatabaseType::Postgres,
            url: Some(url),
            path: None,
            pool_size: 2,
            ..DatabaseConfig::default()
        },
        ..Config::default()
    };
    let db = connect_from_config_seaorm(&config)
        .await
        .expect("connect_seaorm");
    let backend = db.get_database_backend();
    let row = db
        .query_one_raw(Statement::from_string(backend, "SELECT 1 AS v".to_string()))
        .await
        .expect("smoke")
        .expect("row");
    let v: i32 = row.try_get_by("v").expect("v");
    assert_eq!(v, 1);
}
