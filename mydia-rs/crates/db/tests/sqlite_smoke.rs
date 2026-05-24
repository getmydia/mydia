//! `SQLite`-side end-to-end coverage for the post-U6 `SeaORM` data layer:
//! schema-check probe outcomes against a fresh in-memory DB.
//!
//! Wrapper round-trip coverage lives in `wrapper_round_trip.rs`;
//! connection / PRAGMA validation lives in `seaorm_connect_smoke.rs`.
//! This file focuses on the schema-version probe so a regression in
//! `schema_check` fails noisily without dragging the broader wrapper
//! suite along.

use std::path::PathBuf;

use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};
use mydia_rs_db::{
    connect_from_config, schema_check, DatabaseConnection, SchemaCheckOutcome, MAX_KNOWN_MIGRATION,
};
use sea_orm::ConnectionTrait;
use tempfile::TempDir;

fn sqlite_config() -> (Config, TempDir, PathBuf) {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("smoke.db");
    let config = Config {
        database: DatabaseConfig {
            db_type: DatabaseType::Sqlite,
            url: None,
            path: Some(path.to_string_lossy().into_owned()),
            pool_size: 2,
            ..DatabaseConfig::default()
        },
        ..Config::default()
    };
    (config, tmp, path)
}

#[tokio::test]
async fn schema_check_missing_table_returns_schema_missing() {
    let (config, _tmp, _path) = sqlite_config();
    let db = connect_from_config(&config).await.expect("connect");
    let outcome = schema_check(&db).await.expect("probe");
    assert_eq!(outcome, SchemaCheckOutcome::SchemaMissing);
}

#[tokio::test]
async fn schema_check_match_when_version_equals_const() {
    let (config, _tmp, _path) = sqlite_config();
    let db = connect_from_config(&config).await.expect("connect");
    create_schema_migrations_table(&db).await;
    insert_version(&db, MAX_KNOWN_MIGRATION).await;

    let outcome = schema_check(&db).await.expect("probe");
    assert_eq!(
        outcome,
        SchemaCheckOutcome::Match {
            version: MAX_KNOWN_MIGRATION
        }
    );
}

#[tokio::test]
async fn schema_check_ahead_warns_but_continues() {
    let (config, _tmp, _path) = sqlite_config();
    let db = connect_from_config(&config).await.expect("connect");
    create_schema_migrations_table(&db).await;
    let newer = MAX_KNOWN_MIGRATION + 1;
    insert_version(&db, newer).await;

    let outcome = schema_check(&db).await.expect("probe");
    assert_eq!(outcome, SchemaCheckOutcome::SchemaAhead { version: newer });
}

#[tokio::test]
async fn schema_check_too_old_surfaces_for_caller_to_refuse() {
    let (config, _tmp, _path) = sqlite_config();
    let db = connect_from_config(&config).await.expect("connect");
    create_schema_migrations_table(&db).await;
    let older = MAX_KNOWN_MIGRATION - 1;
    insert_version(&db, older).await;

    let outcome = schema_check(&db).await.expect("probe");
    assert_eq!(outcome, SchemaCheckOutcome::SchemaTooOld { version: older });
}

#[tokio::test]
async fn schema_check_empty_table_returns_schema_missing() {
    let (config, _tmp, _path) = sqlite_config();
    let db = connect_from_config(&config).await.expect("connect");
    create_schema_migrations_table(&db).await;
    let outcome = schema_check(&db).await.expect("probe");
    assert_eq!(outcome, SchemaCheckOutcome::SchemaMissing);
}

// ---- helpers ----

async fn create_schema_migrations_table(db: &DatabaseConnection) {
    db.execute_unprepared(
        "CREATE TABLE schema_migrations (
            version BIGINT PRIMARY KEY,
            inserted_at TEXT NOT NULL DEFAULT '2024-01-01T00:00:00Z'
        )",
    )
    .await
    .expect("create migrations table");
}

async fn insert_version(db: &DatabaseConnection, version: i64) {
    db.execute_unprepared(&format!(
        "INSERT INTO schema_migrations (version) VALUES ({version})"
    ))
    .await
    .expect("insert version");
}
