//! Postgres counterpart of `sqlite_smoke.rs`. Gated on `DATABASE_URL`:
//! local runs without a Postgres service skip cleanly; the CI matrix
//! brings up a `postgres:16` service container and exercises every
//! check.
//!
//! Each test drops `schema_migrations` at start so a previous interrupted
//! run leaves no stale rows. Wrapper round-trip coverage lives in
//! `wrapper_round_trip.rs`; connection / PRAGMA validation lives in
//! `seaorm_connect_smoke.rs`.

use std::env;

use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};
use mydia_rs_db::{
    connect_from_config, schema_check, DatabaseConnection, SchemaCheckOutcome, MAX_KNOWN_MIGRATION,
};
use sea_orm::ConnectionTrait;

fn postgres_url() -> Option<String> {
    env::var("DATABASE_URL")
        .ok()
        .filter(|u| u.starts_with("postgres://") || u.starts_with("postgresql://"))
}

fn postgres_config(url: &str) -> Config {
    Config {
        database: DatabaseConfig {
            db_type: DatabaseType::Postgres,
            url: Some(url.into()),
            path: None,
            pool_size: 2,
            ..DatabaseConfig::default()
        },
        ..Config::default()
    }
}

async fn fresh_pool() -> Option<DatabaseConnection> {
    let url = postgres_url()?;
    let db = connect_from_config(&postgres_config(&url)).await.ok()?;
    db.execute_unprepared("DROP TABLE IF EXISTS schema_migrations")
        .await
        .ok()?;
    Some(db)
}

#[tokio::test]
async fn schema_check_missing_table_returns_schema_missing() {
    let Some(db) = fresh_pool().await else { return };

    let outcome = schema_check(&db).await.expect("probe");
    assert_eq!(outcome, SchemaCheckOutcome::SchemaMissing);
}

#[tokio::test]
async fn schema_check_match_when_version_equals_const() {
    let Some(db) = fresh_pool().await else { return };
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
    let Some(db) = fresh_pool().await else { return };
    create_schema_migrations_table(&db).await;
    let newer = MAX_KNOWN_MIGRATION + 1;
    insert_version(&db, newer).await;

    let outcome = schema_check(&db).await.expect("probe");
    assert_eq!(outcome, SchemaCheckOutcome::SchemaAhead { version: newer });
}

#[tokio::test]
async fn schema_check_too_old_surfaces_for_caller_to_refuse() {
    let Some(db) = fresh_pool().await else { return };
    create_schema_migrations_table(&db).await;
    let older = MAX_KNOWN_MIGRATION - 1;
    insert_version(&db, older).await;

    let outcome = schema_check(&db).await.expect("probe");
    assert_eq!(outcome, SchemaCheckOutcome::SchemaTooOld { version: older });
}

#[tokio::test]
async fn schema_check_empty_table_returns_schema_missing() {
    let Some(db) = fresh_pool().await else { return };
    create_schema_migrations_table(&db).await;

    let outcome = schema_check(&db).await.expect("probe");
    assert_eq!(outcome, SchemaCheckOutcome::SchemaMissing);
}

// ---- helpers ----

async fn create_schema_migrations_table(db: &DatabaseConnection) {
    db.execute_unprepared(
        "CREATE TABLE schema_migrations (
            version BIGINT PRIMARY KEY,
            inserted_at TIMESTAMPTZ NOT NULL DEFAULT now()
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
