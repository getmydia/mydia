// Tests: schema setup, raw INSERT/SELECT fixtures, and `sqlx::Type`
// round-trip assertions are tier-(b) by category — runtime form is the
// only sensible shape for ad-hoc CREATE TABLE / INSERT used to seed
// in-memory test state.
#![allow(clippy::disallowed_methods)]

//! End-to-end `SQLite` tests: pool open, smoke query, schema-check probe,
//! and the UUID/datetime `sqlx::Type` round-trip against Ecto's on-disk format.
//!
//! The Postgres counterpart lives in `tests/postgres_smoke.rs` and is
//! gated on `DATABASE_URL` so local runs without a Postgres service skip
//! cleanly while CI exercises both engines.

use std::path::PathBuf;
use std::str::FromStr;

use chrono::{TimeZone, Utc};
use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};
use mydia_rs_db::{
    connect_from_config, schema_check, types::DateTimeMicros, types::DateTimeSecs, types::UuidText,
    Db, SchemaCheckOutcome, MAX_KNOWN_MIGRATION,
};
use sqlx::Row;
use tempfile::TempDir;
use uuid::Uuid;

/// Build a Config pointing at a fresh `SQLite` file inside a temp dir.
/// The temp dir is returned so the caller keeps it alive for the test.
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
async fn connects_and_smokes() {
    let (config, _tmp, _path) = sqlite_config();
    let db = connect_from_config(&config).await.expect("connect");
    assert!(matches!(db, Db::Sqlite(_)));
    let value = db.smoke_query().await.expect("smoke");
    assert_eq!(value, 1);
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
async fn uuid_text_round_trips_as_36_char_hyphenated_lowercase() {
    let (config, _tmp, _path) = sqlite_config();
    let db = connect_from_config(&config).await.expect("connect");
    let pool = db.as_sqlite().expect("sqlite pool");

    sqlx::query("CREATE TABLE t (id TEXT PRIMARY KEY)")
        .execute(pool)
        .await
        .expect("create");

    let id = UuidText::from(Uuid::parse_str("0186fa3d-1c2f-7c4f-9aaa-1234567890ab").unwrap());

    sqlx::query("INSERT INTO t (id) VALUES (?)")
        .bind(id)
        .execute(pool)
        .await
        .expect("insert");

    // 1. On-disk: the raw TEXT must be the lowercase-hyphenated form
    //    Ecto would write.
    let raw: String = sqlx::query("SELECT id FROM t")
        .fetch_one(pool)
        .await
        .expect("read raw")
        .try_get("id")
        .expect("col");
    assert_eq!(raw, "0186fa3d-1c2f-7c4f-9aaa-1234567890ab");

    // 2. Decode: reading back through UuidText recovers the same Uuid.
    let back: UuidText = sqlx::query("SELECT id FROM t")
        .fetch_one(pool)
        .await
        .expect("read uuid")
        .try_get("id")
        .expect("decode");
    assert_eq!(back, id);
}

#[tokio::test]
async fn uuid_text_decodes_phoenix_written_form() {
    let (config, _tmp, _path) = sqlite_config();
    let db = connect_from_config(&config).await.expect("connect");
    let pool = db.as_sqlite().expect("sqlite pool");

    sqlx::query("CREATE TABLE t (id TEXT PRIMARY KEY)")
        .execute(pool)
        .await
        .expect("create");

    // Simulate what Ecto would write directly via raw TEXT.
    sqlx::query("INSERT INTO t (id) VALUES ('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')")
        .execute(pool)
        .await
        .expect("seed");

    let id: UuidText = sqlx::query("SELECT id FROM t")
        .fetch_one(pool)
        .await
        .expect("read")
        .try_get("id")
        .expect("decode");

    assert_eq!(
        id,
        UuidText::from_str("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee").unwrap()
    );
}

#[tokio::test]
async fn datetime_secs_round_trips_as_rfc3339_with_z() {
    let (config, _tmp, _path) = sqlite_config();
    let db = connect_from_config(&config).await.expect("connect");
    let pool = db.as_sqlite().expect("sqlite pool");

    sqlx::query("CREATE TABLE t (at TEXT NOT NULL)")
        .execute(pool)
        .await
        .expect("create");

    let when = DateTimeSecs::from(Utc.with_ymd_and_hms(2026, 5, 21, 12, 34, 56).unwrap());

    sqlx::query("INSERT INTO t (at) VALUES (?)")
        .bind(when)
        .execute(pool)
        .await
        .expect("insert");

    let raw: String = sqlx::query("SELECT at FROM t")
        .fetch_one(pool)
        .await
        .expect("read raw")
        .try_get("at")
        .expect("col");
    // T separator, trailing Z, no fractional seconds. This matches
    // ecto_sqlite3's @default_datetime_type :iso8601 output.
    assert_eq!(raw, "2026-05-21T12:34:56Z");

    let back: DateTimeSecs = sqlx::query("SELECT at FROM t")
        .fetch_one(pool)
        .await
        .expect("read dt")
        .try_get("at")
        .expect("decode");
    assert_eq!(back, when);
}

#[tokio::test]
async fn datetime_micros_round_trips_with_microsecond_suffix() {
    let (config, _tmp, _path) = sqlite_config();
    let db = connect_from_config(&config).await.expect("connect");
    let pool = db.as_sqlite().expect("sqlite pool");

    sqlx::query("CREATE TABLE t (at TEXT NOT NULL)")
        .execute(pool)
        .await
        .expect("create");

    // chrono nanoseconds = micros * 1000; the type truncates on the way in.
    let base = Utc
        .with_ymd_and_hms(2026, 5, 21, 12, 34, 56)
        .unwrap()
        .with_timezone(&Utc);
    let with_us = base + chrono::Duration::microseconds(123_456);
    let when = DateTimeMicros::from(with_us);

    sqlx::query("INSERT INTO t (at) VALUES (?)")
        .bind(when)
        .execute(pool)
        .await
        .expect("insert");

    let raw: String = sqlx::query("SELECT at FROM t")
        .fetch_one(pool)
        .await
        .expect("read raw")
        .try_get("at")
        .expect("col");
    assert_eq!(raw, "2026-05-21T12:34:56.123456Z");

    let back: DateTimeMicros = sqlx::query("SELECT at FROM t")
        .fetch_one(pool)
        .await
        .expect("read dt")
        .try_get("at")
        .expect("decode");
    assert_eq!(back, when);
}

#[tokio::test]
async fn datetime_secs_decodes_legacy_naive_form() {
    // Older mydia rows may have been written with the naive
    // "YYYY-MM-DD HH:MM:SS" form. The decoder must still read them so
    // upgrade-then-read paths don't break.
    let (config, _tmp, _path) = sqlite_config();
    let db = connect_from_config(&config).await.expect("connect");
    let pool = db.as_sqlite().expect("sqlite pool");

    sqlx::query("CREATE TABLE t (at TEXT NOT NULL)")
        .execute(pool)
        .await
        .expect("create");
    sqlx::query("INSERT INTO t (at) VALUES ('2024-01-02 03:04:05')")
        .execute(pool)
        .await
        .expect("seed");

    let back: DateTimeSecs = sqlx::query("SELECT at FROM t")
        .fetch_one(pool)
        .await
        .expect("read")
        .try_get("at")
        .expect("decode");

    assert_eq!(
        back,
        DateTimeSecs::from(Utc.with_ymd_and_hms(2024, 1, 2, 3, 4, 5).unwrap())
    );
}

// ---- helpers ----

async fn create_schema_migrations_table(db: &Db) {
    let pool = db.as_sqlite().expect("sqlite pool");
    sqlx::query(
        "CREATE TABLE schema_migrations (
            version BIGINT PRIMARY KEY,
            inserted_at TEXT NOT NULL DEFAULT '2024-01-01T00:00:00Z'
        )",
    )
    .execute(pool)
    .await
    .expect("create migrations table");
}

async fn insert_version(db: &Db, version: i64) {
    let pool = db.as_sqlite().expect("sqlite pool");
    sqlx::query("INSERT INTO schema_migrations (version) VALUES (?)")
        .bind(version)
        .execute(pool)
        .await
        .expect("insert version");
}
