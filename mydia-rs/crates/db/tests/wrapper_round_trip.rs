//! Round-trip tests for the `SeaORM`-side impls on the type wrappers
//! in `mydia_rs_db::types`. Each test exercises a wrapper's `From<W>
//! for Value`, `TryGetable`, and `into_simple_expr(backend)` end-to-end
//! against a live database — no `ActiveModel` indirection, so these
//! probes isolate wrapper correctness from any downstream helper.
//!
//! Gated on `MYDIA_RS_TEST_SQLITE_URL` (`SQLite`) and `DATABASE_URL`
//! (Postgres). Unset envs skip cleanly. CI's `test-sqlite` and
//! `test-postgres` matrices set the appropriate variable.
//!
//! The wrappers' `SeaORM` impls coexist with their pre-existing `sqlx`
//! impls during the cutover (Phase A). These tests cover the `SeaORM`
//! path; the `sqlx` path stays covered by the existing per-crate test
//! suites until each crate converts in Phase B.

use std::env;

use chrono::{TimeZone, Utc};
use sea_orm::sea_query::{Alias, Expr, Query, Value};
use sea_orm::{ConnectionTrait, Database, DatabaseConnection, DbBackend, Statement};
use serde::{Deserialize, Serialize};

use mydia_rs_db::types::{DateTimeMicros, DateTimeSecs, JsonMap, StringArray, UuidText};

fn postgres_url() -> Option<String> {
    env::var("DATABASE_URL")
        .ok()
        .filter(|u| u.starts_with("postgres://") || u.starts_with("postgresql://"))
}

fn sqlite_url() -> Option<String> {
    env::var("MYDIA_RS_TEST_SQLITE_URL")
        .ok()
        .filter(|u| u.starts_with("sqlite:"))
}

/// Open a Postgres connection from `DATABASE_URL`, mirroring
/// `postgres_smoke.rs`'s soft-skip: when the URL is unset, or when
/// Postgres is not actually reachable (devenv exports the URL even
/// without the postgres service up), return `None` instead of panicking
/// so local `cargo test` runs without bringing Postgres up don't
/// timeout-fail unrelated tests.
async fn connect_postgres() -> Option<DatabaseConnection> {
    let url = postgres_url()?;
    Database::connect(&url).await.ok()
}

async fn exec(db: &DatabaseConnection, sql: &str) {
    db.execute_unprepared(sql)
        .await
        .expect("execute_unprepared");
}

async fn query_one(db: &DatabaseConnection, sql: &str) -> sea_orm::QueryResult {
    let backend = db.get_database_backend();
    db.query_one_raw(Statement::from_string(backend, sql))
        .await
        .expect("query_one_raw")
        .expect("row present")
}

async fn drop_table(db: &DatabaseConnection, table: &str) {
    exec(db, &format!("DROP TABLE IF EXISTS {table}")).await;
}

// ---------- UuidText ----------

async fn round_trip_uuid(db: &DatabaseConnection) {
    let backend = db.get_database_backend();
    let table = "wrap_uuid_round_trip";
    drop_table(db, table).await;
    let id_col_type = match backend {
        DbBackend::Postgres => "uuid",
        DbBackend::Sqlite => "TEXT",
        _ => unreachable!(),
    };
    exec(
        db,
        &format!("CREATE TABLE {table} (id {id_col_type} PRIMARY KEY, label TEXT)"),
    )
    .await;

    let id = UuidText(uuid::Uuid::new_v4());
    let mut stmt = Query::insert();
    stmt.into_table(Alias::new(table))
        .columns([Alias::new("id"), Alias::new("label")])
        .values_panic([
            id.into_simple_expr(backend),
            Expr::Value(Value::String(Some("uuid-rt".to_string()))),
        ]);
    db.execute(&stmt)
        .await
        .expect("insert wrap_uuid_round_trip");

    let row = query_one(db, &format!("SELECT id, label FROM {table}")).await;
    let read: UuidText = row.try_get_by(0).expect("UuidText TryGetable");
    let label: String = row.try_get_by(1).expect("label");
    assert_eq!(read, id, "UuidText round-trip");
    assert_eq!(label, "uuid-rt");

    drop_table(db, table).await;
}

#[tokio::test]
async fn uuid_text_round_trip_sqlite() {
    let Some(url) = sqlite_url() else { return };
    let db = Database::connect(&url).await.expect("connect sqlite");
    round_trip_uuid(&db).await;
}

#[tokio::test]
async fn uuid_text_round_trip_postgres() {
    let Some(db) = connect_postgres().await else {
        return;
    };
    round_trip_uuid(&db).await;
}

#[test]
fn uuid_text_try_from_u64_errors() {
    // TryFromU64 should refuse — UuidText is not numeric. The plan flags
    // this as the wrapper's only error-path guarantee on the PK side.
    use sea_orm::TryFromU64;
    let result = <UuidText as TryFromU64>::try_from_u64(42);
    assert!(matches!(result, Err(sea_orm::DbErr::ConvertFromU64(_))));
}

// ---------- DateTimeSecs / DateTimeMicros ----------

async fn round_trip_datetime_secs(db: &DatabaseConnection) {
    let backend = db.get_database_backend();
    let table = "wrap_datetime_secs_round_trip";
    drop_table(db, table).await;
    let ts_col_type = match backend {
        DbBackend::Postgres => "timestamptz",
        DbBackend::Sqlite => "TEXT",
        _ => unreachable!(),
    };
    exec(
        db,
        &format!("CREATE TABLE {table} (ts {ts_col_type} PRIMARY KEY)"),
    )
    .await;

    // Pick a clean second-precision instant so SQLite TEXT serialization
    // round-trips bit-for-bit (no sub-second rounding to worry about).
    let dt: DateTimeSecs = Utc
        .with_ymd_and_hms(2026, 5, 24, 12, 34, 56)
        .unwrap()
        .into();

    let mut stmt = Query::insert();
    stmt.into_table(Alias::new(table))
        .columns([Alias::new("ts")])
        .values_panic([dt.into_simple_expr(backend)]);
    db.execute(&stmt).await.expect("insert datetime_secs");

    let row = query_one(db, &format!("SELECT ts FROM {table}")).await;
    let read: DateTimeSecs = row.try_get_by(0).expect("DateTimeSecs TryGetable");
    assert_eq!(read, dt, "DateTimeSecs round-trip");

    drop_table(db, table).await;
}

#[tokio::test]
async fn datetime_secs_round_trip_sqlite() {
    let Some(url) = sqlite_url() else { return };
    let db = Database::connect(&url).await.expect("connect sqlite");
    round_trip_datetime_secs(&db).await;
}

#[tokio::test]
async fn datetime_secs_round_trip_postgres() {
    let Some(db) = connect_postgres().await else {
        return;
    };
    round_trip_datetime_secs(&db).await;
}

async fn round_trip_datetime_micros(db: &DatabaseConnection) {
    let backend = db.get_database_backend();
    let table = "wrap_datetime_micros_round_trip";
    drop_table(db, table).await;
    let ts_col_type = match backend {
        DbBackend::Postgres => "timestamptz",
        DbBackend::Sqlite => "TEXT",
        _ => unreachable!(),
    };
    exec(
        db,
        &format!("CREATE TABLE {table} (ts {ts_col_type} PRIMARY KEY)"),
    )
    .await;

    // 123456 µs — confirms the wrapper preserves microsecond precision
    // through serialization and TryGetable parsing on both engines.
    let raw = Utc
        .with_ymd_and_hms(2026, 5, 24, 12, 34, 56)
        .unwrap()
        .with_timezone(&Utc)
        + chrono::Duration::microseconds(123_456);
    let dt: DateTimeMicros = raw.into();

    let mut stmt = Query::insert();
    stmt.into_table(Alias::new(table))
        .columns([Alias::new("ts")])
        .values_panic([dt.into_simple_expr(backend)]);
    db.execute(&stmt).await.expect("insert datetime_micros");

    let row = query_one(db, &format!("SELECT ts FROM {table}")).await;
    let read: DateTimeMicros = row.try_get_by(0).expect("DateTimeMicros TryGetable");
    assert_eq!(
        read.0.timestamp_subsec_micros(),
        123_456,
        "micros preserved"
    );
    assert_eq!(read, dt, "DateTimeMicros round-trip");

    drop_table(db, table).await;
}

#[tokio::test]
async fn datetime_micros_round_trip_sqlite() {
    let Some(url) = sqlite_url() else { return };
    let db = Database::connect(&url).await.expect("connect sqlite");
    round_trip_datetime_micros(&db).await;
}

#[tokio::test]
async fn datetime_micros_round_trip_postgres() {
    let Some(db) = connect_postgres().await else {
        return;
    };
    round_trip_datetime_micros(&db).await;
}

// ---------- JsonMap<T> ----------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct TestPayload {
    name: String,
    tags: Vec<String>,
    count: Option<i64>,
    nested: NestedPayload,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct NestedPayload {
    label: String,
    flag: bool,
}

async fn round_trip_json_map(db: &DatabaseConnection) {
    let backend = db.get_database_backend();
    let table = "wrap_json_map_round_trip";
    drop_table(db, table).await;
    let payload_col_type = match backend {
        DbBackend::Postgres => "jsonb",
        DbBackend::Sqlite => "TEXT",
        _ => unreachable!(),
    };
    exec(
        db,
        &format!("CREATE TABLE {table} (id INTEGER PRIMARY KEY, payload {payload_col_type})"),
    )
    .await;

    let payload = TestPayload {
        name: "alpha".to_string(),
        tags: vec!["a".to_string(), "b".to_string(), "c".to_string()],
        count: Some(42),
        nested: NestedPayload {
            label: "n1".to_string(),
            flag: true,
        },
    };
    let wrapped: JsonMap<TestPayload> = JsonMap(payload.clone());

    let mut stmt = Query::insert();
    stmt.into_table(Alias::new(table))
        .columns([Alias::new("id"), Alias::new("payload")])
        .values_panic([
            Expr::Value(Value::Int(Some(1))),
            wrapped.into_simple_expr(backend),
        ]);
    db.execute(&stmt).await.expect("insert json_map");

    let row = query_one(db, &format!("SELECT payload FROM {table} WHERE id = 1")).await;
    let read: JsonMap<TestPayload> = row.try_get_by(0).expect("JsonMap TryGetable");
    assert_eq!(read.0, payload, "JsonMap round-trip");

    drop_table(db, table).await;
}

#[tokio::test]
async fn json_map_round_trip_sqlite() {
    let Some(url) = sqlite_url() else { return };
    let db = Database::connect(&url).await.expect("connect sqlite");
    round_trip_json_map(&db).await;
}

#[tokio::test]
async fn json_map_round_trip_postgres() {
    let Some(db) = connect_postgres().await else {
        return;
    };
    round_trip_json_map(&db).await;
}

// ---------- StringArray ----------

async fn round_trip_string_array(db: &DatabaseConnection, label: &str, values: Vec<String>) {
    let backend = db.get_database_backend();
    let table = format!("wrap_string_array_{label}");
    drop_table(db, &table).await;
    let arr_col_type = match backend {
        DbBackend::Postgres => "text[]",
        DbBackend::Sqlite => "TEXT",
        _ => unreachable!(),
    };
    exec(
        db,
        &format!("CREATE TABLE {table} (id INTEGER PRIMARY KEY, perms {arr_col_type})"),
    )
    .await;

    let wrapped = StringArray(values.clone());

    let mut stmt = Query::insert();
    stmt.into_table(Alias::new(&table))
        .columns([Alias::new("id"), Alias::new("perms")])
        .values_panic([
            Expr::Value(Value::Int(Some(1))),
            wrapped.into_simple_expr(backend),
        ]);
    db.execute(&stmt)
        .await
        .unwrap_or_else(|e| panic!("insert string_array ({label}): {e}"));

    let row = query_one(db, &format!("SELECT perms FROM {table} WHERE id = 1")).await;
    let read: StringArray = row.try_get_by(0).expect("StringArray TryGetable");
    assert_eq!(read.0, values, "StringArray round-trip ({label})");

    drop_table(db, &table).await;
}

async fn string_array_suite(db: &DatabaseConnection) {
    // Happy path: a couple of perm strings.
    round_trip_string_array(db, "happy", vec!["read".to_string(), "write".to_string()]).await;
    // Order preservation: not sorted.
    round_trip_string_array(
        db,
        "order",
        vec![
            "charlie".to_string(),
            "alpha".to_string(),
            "bravo".to_string(),
        ],
    )
    .await;
    // Empty array.
    round_trip_string_array(db, "empty", Vec::<String>::new()).await;
}

#[tokio::test]
async fn string_array_round_trip_sqlite() {
    let Some(url) = sqlite_url() else { return };
    let db = Database::connect(&url).await.expect("connect sqlite");
    string_array_suite(&db).await;
}

#[tokio::test]
async fn string_array_round_trip_postgres() {
    let Some(db) = connect_postgres().await else {
        return;
    };
    string_array_suite(&db).await;
}
