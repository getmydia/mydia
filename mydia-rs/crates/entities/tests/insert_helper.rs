//! Round-trip tests for the workspace `insert_active_model` and
//! `update_active_model` helpers. These exercise the engine-aware
//! `ActiveModel` → `InsertStatement` / `UpdateStatement` path that replaces
//! vanilla `am.insert(&db)` / `am.update(&db)` for tables whose columns
//! carry the cross-engine wrapper types in `mydia_rs_db::types`.
//!
//! Test entity choices favor tables with empty `Relation` enums so
//! `Schema::create_table_from_entity` emits no foreign keys — this keeps
//! each test independent and avoids parent-table setup boilerplate.
//! Production coverage of FK-bearing tables lives in the per-crate
//! Phase B units; the U5 schema-diff-check CI gate validates entities
//! match the Phoenix-migrated schema on Postgres.
//!
//! Gated on `MYDIA_RS_TEST_SQLITE_URL` and `DATABASE_URL`, same as
//! `wrapper_round_trip.rs`. Unset envs skip cleanly.

use std::env;

use chrono::{TimeZone, Utc};
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{
    ActiveValue, ConnectionTrait, Database, DatabaseBackend, DatabaseConnection, DbBackend, DbErr,
    EntityTrait, QueryFilter, Set,
};
use serde_json::json;
use serial_test::serial;

use mydia_rs_db::types::{DateTimeMicros, DateTimeSecs, JsonMap, StringArray, UuidText};
use mydia_rs_db::{insert_active_model, update_active_model};
use mydia_rs_entities::{release_blacklist, remote_access_config};

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

async fn connect_postgres() -> Option<DatabaseConnection> {
    let url = postgres_url()?;
    Database::connect(&url).await.ok()
}

async fn drop_table(db: &DatabaseConnection, table: &str) {
    db.execute_unprepared(&format!("DROP TABLE IF EXISTS \"{table}\""))
        .await
        .expect("drop table");
}

/// Engine-aware DDL the test fixtures use to bootstrap a table without
/// going through `Schema::create_table_from_entity`.
///
/// `Schema::create_table_from_entity` panics on `SQLite` for entities with
/// `ColumnType::Array(_)` columns — sea-query's `SQLite` builder refuses
/// the variant (`Array is not available in Sqlite`). Phoenix stores
/// those columns as TEXT-holding-JSON on `SQLite` (per migration
/// `20260223100000_fix_array_columns_for_postgres.exs`), so the
/// wrappers marshal them as `Value::String`. Test fixtures need to
/// reflect that engine-specific storage shape, which means hand-crafted
/// CREATE TABLE SQL per backend until U18's `runtime_lock` helper grows a
/// `create_table_for_entity` wrapper that engine-rewrites Array→Text.
async fn create_table_engine_aware(db: &DatabaseConnection, sqlite_sql: &str, postgres_sql: &str) {
    let sql = match db.get_database_backend() {
        DbBackend::Sqlite => sqlite_sql,
        DbBackend::Postgres => postgres_sql,
        _ => unreachable!("mydia-rs is dual-engine SQLite/Postgres only"),
    };
    db.execute_unprepared(sql).await.expect("create table");
}

// CREATE TABLE statements mirroring Phoenix's
// `priv/repo/migrations/*.exs` output for `remote_access_config`,
// `release_blacklist`, and the synthetic JSON test table. Kept in
// lockstep with `mydia_rs_entities::*` Model annotations.
const SQLITE_REMOTE_ACCESS_CONFIG: &str = r"
CREATE TABLE remote_access_config (
    id TEXT PRIMARY KEY NOT NULL,
    instance_id TEXT NOT NULL UNIQUE,
    static_public_key BLOB NOT NULL,
    static_private_key_encrypted BLOB NOT NULL,
    enabled INTEGER NOT NULL,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    cert_fingerprint TEXT,
    relay_token TEXT,
    direct_urls TEXT
)";
const POSTGRES_REMOTE_ACCESS_CONFIG: &str = r"
CREATE TABLE remote_access_config (
    id uuid PRIMARY KEY NOT NULL,
    instance_id text NOT NULL UNIQUE,
    static_public_key bytea NOT NULL,
    static_private_key_encrypted bytea NOT NULL,
    enabled boolean NOT NULL,
    inserted_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    cert_fingerprint text,
    relay_token text,
    direct_urls text[]
)";

const SQLITE_RELEASE_BLACKLIST: &str = r"
CREATE TABLE release_blacklist (
    id TEXT PRIMARY KEY NOT NULL,
    indexer TEXT NOT NULL,
    guid TEXT NOT NULL,
    title TEXT NOT NULL,
    failure_reason TEXT NOT NULL,
    expires_at TEXT,
    inserted_at TEXT NOT NULL,
    UNIQUE (indexer, guid)
)";
const POSTGRES_RELEASE_BLACKLIST: &str = r"
CREATE TABLE release_blacklist (
    id uuid PRIMARY KEY NOT NULL,
    indexer text NOT NULL,
    guid text NOT NULL,
    title text NOT NULL,
    failure_reason text NOT NULL,
    expires_at timestamptz,
    inserted_at timestamptz NOT NULL,
    UNIQUE (indexer, guid)
)";

const SQLITE_JSONMAP_TEST: &str = r"
CREATE TABLE _test_jsonmap_round_trip (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    payload TEXT NOT NULL,
    maybe_payload TEXT,
    tags TEXT,
    created_at TEXT NOT NULL
)";
const POSTGRES_JSONMAP_TEST: &str = r"
CREATE TABLE _test_jsonmap_round_trip (
    id uuid PRIMARY KEY NOT NULL,
    name text NOT NULL,
    payload jsonb NOT NULL,
    maybe_payload jsonb,
    tags text[],
    created_at timestamptz NOT NULL
)";

// ---------- remote_access_config: UuidText PK + StringArray + DateTimeSecs ----------

async fn round_trip_remote_access_config(db: &DatabaseConnection) {
    drop_table(db, "remote_access_config").await;
    create_table_engine_aware(
        db,
        SQLITE_REMOTE_ACCESS_CONFIG,
        POSTGRES_REMOTE_ACCESS_CONFIG,
    )
    .await;

    let id = UuidText::new_v4();
    let now = DateTimeSecs::from(Utc::now());
    let urls = StringArray::from(vec![
        "https://node-1.example".to_string(),
        "https://node-2.example".to_string(),
    ]);
    let am = remote_access_config::ActiveModel {
        id: Set(id),
        instance_id: Set("test-instance".to_string()),
        static_public_key: Set(vec![1u8, 2, 3, 4]),
        static_private_key_encrypted: Set(vec![5u8, 6, 7, 8]),
        enabled: Set(true),
        inserted_at: Set(now),
        updated_at: Set(now),
        cert_fingerprint: Set(None),
        relay_token: Set(Some("relay-tok".to_string())),
        direct_urls: Set(Some(urls.clone())),
    };

    let inserted = insert_active_model(am, db)
        .await
        .expect("insert remote_access_config");
    assert_eq!(inserted.id, id);
    assert_eq!(inserted.instance_id, "test-instance");
    assert_eq!(inserted.static_public_key, vec![1, 2, 3, 4]);
    assert!(inserted.enabled);
    assert_eq!(inserted.relay_token.as_deref(), Some("relay-tok"));
    assert_eq!(inserted.direct_urls, Some(urls.clone()));

    // Refetch to confirm the row actually persisted with the expected
    // wrapper values. The vanilla `Entity::find_by_id(uuid_text)` path
    // fails on Postgres because `Column::Id.eq(value)` binds as TEXT
    // against a `uuid` column — Phase B converts call sites to the
    // `Column::Id.eq(wrapper.into_simple_expr(backend))` pattern instead
    // (mirrored here so the test verifies the same idiom production
    // code will use).
    let backend = db.get_database_backend();
    let found = remote_access_config::Entity::find()
        .filter(Expr::col(remote_access_config::Column::Id).eq(id.into_simple_expr(backend)))
        .one(db)
        .await
        .expect("find with cast")
        .expect("row present");
    assert_eq!(found.direct_urls, Some(urls));
    assert_eq!(found.inserted_at, now);

    drop_table(db, "remote_access_config").await;
}

#[tokio::test]
async fn remote_access_config_round_trip_sqlite() {
    let Some(url) = sqlite_url() else { return };
    let db = Database::connect(&url).await.expect("connect sqlite");
    round_trip_remote_access_config(&db).await;
}

#[tokio::test]
#[serial(remote_access_config)]
async fn remote_access_config_round_trip_postgres() {
    let Some(db) = connect_postgres().await else {
        return;
    };
    round_trip_remote_access_config(&db).await;
}

// ---------- remote_access_config: empty StringArray ----------

async fn empty_string_array(db: &DatabaseConnection) {
    drop_table(db, "remote_access_config").await;
    create_table_engine_aware(
        db,
        SQLITE_REMOTE_ACCESS_CONFIG,
        POSTGRES_REMOTE_ACCESS_CONFIG,
    )
    .await;

    let id = UuidText::new_v4();
    let now = DateTimeSecs::from(Utc::now());
    let am = remote_access_config::ActiveModel {
        id: Set(id),
        instance_id: Set("empty-urls".to_string()),
        static_public_key: Set(vec![0u8]),
        static_private_key_encrypted: Set(vec![0u8]),
        enabled: Set(false),
        inserted_at: Set(now),
        updated_at: Set(now),
        cert_fingerprint: Set(None),
        relay_token: Set(None),
        direct_urls: Set(Some(StringArray::from(Vec::<String>::new()))),
    };

    let inserted = insert_active_model(am, db).await.expect("insert");
    assert_eq!(
        inserted.direct_urls,
        Some(StringArray::from(Vec::<String>::new()))
    );

    drop_table(db, "remote_access_config").await;
}

#[tokio::test]
async fn empty_string_array_sqlite() {
    let Some(url) = sqlite_url() else { return };
    let db = Database::connect(&url).await.expect("connect sqlite");
    empty_string_array(&db).await;
}

#[tokio::test]
#[serial(remote_access_config)]
async fn empty_string_array_postgres() {
    let Some(db) = connect_postgres().await else {
        return;
    };
    empty_string_array(&db).await;
}

// ---------- release_blacklist: UuidText PK + DateTimeMicros ----------

async fn round_trip_release_blacklist(db: &DatabaseConnection) {
    drop_table(db, "release_blacklist").await;
    create_table_engine_aware(db, SQLITE_RELEASE_BLACKLIST, POSTGRES_RELEASE_BLACKLIST).await;

    let id = UuidText::new_v4();
    // 123_456 µs — confirms microsecond precision survives the helper's
    // engine-aware bind on both engines.
    let inserted_at_dt: DateTimeMicros = (Utc.with_ymd_and_hms(2026, 5, 24, 12, 0, 0).unwrap()
        + chrono::Duration::microseconds(123_456))
    .into();
    let am = release_blacklist::ActiveModel {
        id: Set(id),
        indexer: Set("nzbgeek".to_string()),
        guid: Set("guid-123".to_string()),
        title: Set("Some Release".to_string()),
        failure_reason: Set("title_mismatch".to_string()),
        expires_at: Set(None),
        inserted_at: Set(inserted_at_dt),
    };

    let inserted = insert_active_model(am, db)
        .await
        .expect("insert release_blacklist");
    assert_eq!(inserted.id, id);
    assert_eq!(inserted.title, "Some Release");
    assert_eq!(
        inserted.inserted_at.0.timestamp_subsec_micros(),
        123_456,
        "microseconds preserved"
    );

    drop_table(db, "release_blacklist").await;
}

#[tokio::test]
async fn release_blacklist_round_trip_sqlite() {
    let Some(url) = sqlite_url() else { return };
    let db = Database::connect(&url).await.expect("connect sqlite");
    round_trip_release_blacklist(&db).await;
}

#[tokio::test]
#[serial(release_blacklist)]
async fn release_blacklist_round_trip_postgres() {
    let Some(db) = connect_postgres().await else {
        return;
    };
    round_trip_release_blacklist(&db).await;
}

// ---------- UPDATE: remote_access_config ----------

async fn update_remote_access_config(db: &DatabaseConnection) {
    drop_table(db, "remote_access_config").await;
    create_table_engine_aware(
        db,
        SQLITE_REMOTE_ACCESS_CONFIG,
        POSTGRES_REMOTE_ACCESS_CONFIG,
    )
    .await;

    let id = UuidText::new_v4();
    let now = DateTimeSecs::from(Utc::now());
    let initial_urls = StringArray::from(vec!["https://a.example".to_string()]);
    let am = remote_access_config::ActiveModel {
        id: Set(id),
        instance_id: Set("upd-test".to_string()),
        static_public_key: Set(vec![1u8]),
        static_private_key_encrypted: Set(vec![2u8]),
        enabled: Set(false),
        inserted_at: Set(now),
        updated_at: Set(now),
        cert_fingerprint: Set(None),
        relay_token: Set(None),
        direct_urls: Set(Some(initial_urls.clone())),
    };
    insert_active_model(am, db).await.expect("seed insert");

    // Now update enabled, relay_token, and direct_urls. PK is Unchanged.
    let new_urls = StringArray::from(vec![
        "https://b.example".to_string(),
        "https://c.example".to_string(),
    ]);
    let update_am = remote_access_config::ActiveModel {
        id: ActiveValue::Unchanged(id),
        enabled: Set(true),
        relay_token: Set(Some("new-tok".to_string())),
        direct_urls: Set(Some(new_urls.clone())),
        ..Default::default()
    };
    let updated = update_active_model(update_am, db)
        .await
        .expect("update remote_access_config");
    assert_eq!(updated.id, id);
    assert!(updated.enabled);
    assert_eq!(updated.relay_token.as_deref(), Some("new-tok"));
    assert_eq!(updated.direct_urls, Some(new_urls));
    // Unchanged column survives.
    assert_eq!(updated.instance_id, "upd-test");

    drop_table(db, "remote_access_config").await;
}

#[tokio::test]
async fn update_remote_access_config_sqlite() {
    let Some(url) = sqlite_url() else { return };
    let db = Database::connect(&url).await.expect("connect sqlite");
    update_remote_access_config(&db).await;
}

#[tokio::test]
#[serial(remote_access_config)]
async fn update_remote_access_config_postgres() {
    let Some(db) = connect_postgres().await else {
        return;
    };
    update_remote_access_config(&db).await;
}

// ---------- Duplicate primary key surfaces DbErr, not panic ----------

async fn duplicate_pk_errors(db: &DatabaseConnection) {
    drop_table(db, "remote_access_config").await;
    create_table_engine_aware(
        db,
        SQLITE_REMOTE_ACCESS_CONFIG,
        POSTGRES_REMOTE_ACCESS_CONFIG,
    )
    .await;

    let id = UuidText::new_v4();
    let now = DateTimeSecs::from(Utc::now());
    let build_am = |instance: &str| remote_access_config::ActiveModel {
        id: Set(id),
        instance_id: Set(instance.to_string()),
        static_public_key: Set(vec![1u8]),
        static_private_key_encrypted: Set(vec![2u8]),
        enabled: Set(false),
        inserted_at: Set(now),
        updated_at: Set(now),
        cert_fingerprint: Set(None),
        relay_token: Set(None),
        direct_urls: Set(None),
    };

    insert_active_model(build_am("first"), db)
        .await
        .expect("first insert");
    let err = insert_active_model(build_am("second"), db)
        .await
        .expect_err("expected duplicate PK error");
    // The exact DbErr variant differs across backends (Postgres surfaces
    // through `Exec`; SQLite through `Exec` or `Query`). The contract is
    // "returns an error", not which one.
    assert!(
        !matches!(err, DbErr::RecordNotFound(_)),
        "duplicate insert should not look like 'record not found': {err:?}"
    );

    drop_table(db, "remote_access_config").await;
}

#[tokio::test]
async fn duplicate_pk_errors_sqlite() {
    let Some(url) = sqlite_url() else { return };
    let db = Database::connect(&url).await.expect("connect sqlite");
    duplicate_pk_errors(&db).await;
}

#[tokio::test]
#[serial(remote_access_config)]
async fn duplicate_pk_errors_postgres() {
    let Some(db) = connect_postgres().await else {
        return;
    };
    duplicate_pk_errors(&db).await;
}

// ---------- JsonMap dispatch via library_paths (FK columns set to None) ----------
//
// `library_paths` is the densest mydia entity touching `JsonMap` plus an
// `Option<UuidText>` FK column. The helper has to recognize the JSONB
// column type and cast on Postgres while leaving the optional FK columns
// alone (they're NULL here, so they fall through the "no cast" path).
//
// We can't use `library_paths::Entity` with `create_table_from_entity`
// directly because its `Relation` enum declares belongs_to relations
// that emit FK constraints to `quality_profiles` and `users`. Instead,
// the test exercises a synthetic entity that mirrors the wrapper
// surface so the helper's column-type dispatch is the thing under test,
// not Schema codegen.

mod jsonmap_entity {
    use mydia_rs_db::types::{DateTimeSecs, JsonMap, StringArray, UuidText};
    use sea_orm::entity::prelude::*;
    use serde::{Deserialize, Serialize};

    #[derive(Clone, Debug, PartialEq, Eq, DeriveEntityModel, Serialize, Deserialize)]
    #[sea_orm(table_name = "_test_jsonmap_round_trip")]
    pub struct Model {
        #[sea_orm(primary_key, auto_increment = false)]
        pub id: UuidText,
        pub name: String,
        #[sea_orm(column_type = "JsonBinary")]
        pub payload: JsonMap<serde_json::Value>,
        #[sea_orm(column_type = "JsonBinary", nullable)]
        pub maybe_payload: Option<JsonMap<serde_json::Value>>,
        #[sea_orm(column_type = "Array(ColumnType::Text.into())", nullable)]
        pub tags: Option<StringArray>,
        pub created_at: DateTimeSecs,
    }

    #[derive(Copy, Clone, Debug, EnumIter, DeriveRelation)]
    pub enum Relation {}

    impl ActiveModelBehavior for ActiveModel {}
}

async fn round_trip_jsonmap(db: &DatabaseConnection) {
    drop_table(db, "_test_jsonmap_round_trip").await;
    create_table_engine_aware(db, SQLITE_JSONMAP_TEST, POSTGRES_JSONMAP_TEST).await;

    let id = UuidText::new_v4();
    let payload = json!({
        "key1": "value1",
        "nested": { "inner": [1, 2, 3] },
        "flag": true,
    });
    let am = jsonmap_entity::ActiveModel {
        id: Set(id),
        name: Set("alpha".to_string()),
        payload: Set(JsonMap(payload.clone())),
        maybe_payload: Set(None),
        tags: Set(Some(StringArray::from(vec![
            "tag-a".to_string(),
            "tag-b".to_string(),
        ]))),
        created_at: Set(DateTimeSecs::from(Utc::now())),
    };

    let inserted = insert_active_model(am, db).await.expect("insert jsonmap");
    assert_eq!(inserted.id, id);
    assert_eq!(inserted.payload.0, payload);
    assert_eq!(inserted.maybe_payload, None);

    let backend = db.get_database_backend();
    let found = jsonmap_entity::Entity::find()
        .filter(Expr::col(jsonmap_entity::Column::Id).eq(id.into_simple_expr(backend)))
        .one(db)
        .await
        .expect("find with cast")
        .expect("row present");
    assert_eq!(found.payload.0, payload);
    assert_eq!(
        found.tags,
        Some(StringArray::from(vec![
            "tag-a".to_string(),
            "tag-b".to_string()
        ]))
    );

    drop_table(db, "_test_jsonmap_round_trip").await;
}

#[tokio::test]
async fn jsonmap_round_trip_sqlite() {
    let Some(url) = sqlite_url() else { return };
    let db = Database::connect(&url).await.expect("connect sqlite");
    round_trip_jsonmap(&db).await;
}

#[tokio::test]
#[serial(jsonmap_round_trip)]
async fn jsonmap_round_trip_postgres() {
    let Some(db) = connect_postgres().await else {
        return;
    };
    round_trip_jsonmap(&db).await;
}

// ---------- Backend smoke (helper sanity-checks the backend variant) ----------

#[test]
fn backend_smoke_compiles() {
    // No-op test: presence proves the helper's public surface compiles
    // against the rest of the crate. Exists primarily so `cargo check
    // --tests -p mydia-rs-db` exercises the test file even when neither
    // DB URL env is set.
    let _ = (DatabaseBackend::Sqlite, DbBackend::Postgres);
}
