//! Postgres counterpart of `sqlite_smoke.rs`. Gated on `DATABASE_URL`:
//! local runs without a Postgres service skip cleanly, the CI matrix
//! brings up a `postgres:16` service container and exercises every
//! check.
//!
//! Each test uses a private schema namespace so concurrent test bodies
//! don't trample each other's tables. Cleanup runs at the start of each
//! test rather than the end so a previous interrupted run leaves no
//! stale rows.

use std::env;

use chrono::{TimeZone, Utc};
use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};
use mydia_rs_db::{
    connect_from_config, schema_check, types::DateTimeMicros, types::DateTimeSecs, types::UuidText,
    Db, SchemaCheckOutcome, MAX_KNOWN_MIGRATION,
};
use sqlx::Row;
use uuid::Uuid;

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

async fn fresh_pool() -> Option<Db> {
    let url = postgres_url()?;
    let db = connect_from_config(&postgres_config(&url)).await.ok()?;
    Some(db)
}

#[tokio::test]
async fn connects_and_smokes() {
    let Some(db) = fresh_pool().await else { return };
    assert!(matches!(db, Db::Postgres(_)));
    let value = db.smoke_query().await.expect("smoke");
    assert_eq!(value, 1);
}

#[tokio::test]
async fn schema_check_missing_table_returns_schema_missing() {
    let Some(db) = fresh_pool().await else { return };
    let pool = db.as_postgres().expect("postgres pool");
    sqlx::query("DROP TABLE IF EXISTS schema_migrations")
        .execute(pool)
        .await
        .expect("drop");

    let outcome = schema_check(&db).await.expect("probe");
    assert_eq!(outcome, SchemaCheckOutcome::SchemaMissing);
}

#[tokio::test]
async fn schema_check_match_when_version_equals_const() {
    let Some(db) = fresh_pool().await else { return };
    let pool = db.as_postgres().expect("postgres pool");
    sqlx::query("DROP TABLE IF EXISTS schema_migrations")
        .execute(pool)
        .await
        .expect("drop");
    sqlx::query(
        "CREATE TABLE schema_migrations (
            version BIGINT PRIMARY KEY,
            inserted_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )",
    )
    .execute(pool)
    .await
    .expect("create");
    sqlx::query("INSERT INTO schema_migrations (version) VALUES ($1)")
        .bind(MAX_KNOWN_MIGRATION)
        .execute(pool)
        .await
        .expect("insert");

    let outcome = schema_check(&db).await.expect("probe");
    assert_eq!(
        outcome,
        SchemaCheckOutcome::Match {
            version: MAX_KNOWN_MIGRATION
        }
    );
}

#[tokio::test]
async fn uuid_text_round_trips_via_native_uuid_type() {
    let Some(db) = fresh_pool().await else { return };
    let pool = db.as_postgres().expect("postgres pool");
    sqlx::query("DROP TABLE IF EXISTS t_uuid")
        .execute(pool)
        .await
        .expect("drop");
    sqlx::query("CREATE TABLE t_uuid (id UUID PRIMARY KEY)")
        .execute(pool)
        .await
        .expect("create");

    let id = UuidText::from(Uuid::parse_str("0186fa3d-1c2f-7c4f-9aaa-1234567890ab").unwrap());
    sqlx::query("INSERT INTO t_uuid (id) VALUES ($1)")
        .bind(id)
        .execute(pool)
        .await
        .expect("insert");

    let back: UuidText = sqlx::query("SELECT id FROM t_uuid")
        .fetch_one(pool)
        .await
        .expect("read")
        .try_get("id")
        .expect("decode");
    assert_eq!(back, id);
}

#[tokio::test]
async fn datetime_secs_round_trips_via_timestamptz() {
    let Some(db) = fresh_pool().await else { return };
    let pool = db.as_postgres().expect("postgres pool");
    sqlx::query("DROP TABLE IF EXISTS t_dt_secs")
        .execute(pool)
        .await
        .expect("drop");
    sqlx::query("CREATE TABLE t_dt_secs (at TIMESTAMPTZ NOT NULL)")
        .execute(pool)
        .await
        .expect("create");

    let when = DateTimeSecs::from(Utc.with_ymd_and_hms(2026, 5, 21, 12, 34, 56).unwrap());
    sqlx::query("INSERT INTO t_dt_secs (at) VALUES ($1)")
        .bind(when)
        .execute(pool)
        .await
        .expect("insert");

    let back: DateTimeSecs = sqlx::query("SELECT at FROM t_dt_secs")
        .fetch_one(pool)
        .await
        .expect("read")
        .try_get("at")
        .expect("decode");
    assert_eq!(back, when);
}

#[tokio::test]
async fn datetime_micros_round_trips_via_timestamptz() {
    let Some(db) = fresh_pool().await else { return };
    let pool = db.as_postgres().expect("postgres pool");
    sqlx::query("DROP TABLE IF EXISTS t_dt_us")
        .execute(pool)
        .await
        .expect("drop");
    sqlx::query("CREATE TABLE t_dt_us (at TIMESTAMPTZ NOT NULL)")
        .execute(pool)
        .await
        .expect("create");

    let base = Utc.with_ymd_and_hms(2026, 5, 21, 12, 34, 56).unwrap();
    let with_us = base + chrono::Duration::microseconds(123_456);
    let when = DateTimeMicros::from(with_us);
    sqlx::query("INSERT INTO t_dt_us (at) VALUES ($1)")
        .bind(when)
        .execute(pool)
        .await
        .expect("insert");

    let back: DateTimeMicros = sqlx::query("SELECT at FROM t_dt_us")
        .fetch_one(pool)
        .await
        .expect("read")
        .try_get("at")
        .expect("decode");
    assert_eq!(back, when);
}
