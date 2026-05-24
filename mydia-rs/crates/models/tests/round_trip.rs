//! Round-trip integration tests for the per-table wrapper-typed columns
//! the `mydia_rs_models` structs mirror.
//!
//! Post-U15 cutover: the round-trips run through `SeaORM` entities and
//! the workspace `insert_active_model` helper, not raw sqlx. The
//! `mydia_rs_models` structs themselves are wire/serialization types now
//! — the on-disk shape is owned by `mydia_rs_entities::*::Model`. These
//! tests exercise the column-by-column round-trip of each
//! Phoenix-shaped table the models mirror, by:
//!
//!   1. Spinning up an in-process `SQLite` connection via
//!      `mydia_rs_db::connect_from_config`.
//!   2. Creating the table with engine-specific DDL that matches the
//!      Phoenix schema (TEXT for wrapper columns on `SQLite`, matching the
//!      Ecto adapter's storage shape).
//!   3. Inserting a row via `mydia_rs_db::insert_active_model` so the
//!      wrapper-typed columns flow through the engine-aware write path.
//!   4. Reading the row back via `Entity::find_by_id` and asserting field
//!      values round-trip.
//!
//! `Schema::create_table_from_entity` is not used here because it panics
//! on `SQLite` for entities with `ColumnType::Array(_)` columns (`api_keys`'
//! `permissions`), and it would emit foreign-key constraints for tables
//! whose FK targets aren't created in scope. Hand-written DDL is the
//! pattern `crates/entities/tests/insert_helper.rs` already uses for the
//! same reasons.
//!
//! Foreign-key constraints are disabled at the `SQLite` level via the
//! `foreign_keys = OFF` PRAGMA because tests like `episode_round_trips`
//! reference a parent `media_items.id` without seeding the parent row.
//! Phoenix's Ecto migrations declare those FKs; production code seeds
//! parents before children. Tests in this file isolate the column-level
//! round-trip and intentionally skip parent setup.

use std::collections::HashMap;

use chrono::{NaiveDate, TimeZone, Utc};
use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};
use mydia_rs_db::{
    connect_from_config, insert_active_model,
    types::{DateTimeSecs, JsonMap, StringArray, UuidText},
};
use mydia_rs_entities::{
    api_keys, episodes, library_paths, media_files, media_items, subtitles, users,
};
use mydia_rs_models::{
    api_key::VALID_PERMISSIONS,
    library_path::{LibraryPathKind, ScanStatus},
    media_item::{MediaKind, MonitoringPreset},
    user::UserRole,
    Subtitle,
};
use sea_orm::{ActiveValue::Set, ConnectionTrait, DatabaseConnection, EntityTrait};
use tempfile::TempDir;
use uuid::Uuid;

/// Spin up a fresh `SQLite` database, disable foreign keys (each test
/// table is created in isolation without its FK parents), and return
/// the `SeaORM` `DatabaseConnection` plus the holding `TempDir` so the
/// caller can keep the file alive.
async fn fresh_sqlite() -> (DatabaseConnection, TempDir) {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("models.db");
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
    let db = connect_from_config(&config).await.expect("connect");
    db.execute_unprepared("PRAGMA foreign_keys = OFF")
        .await
        .expect("disable FK");
    (db, tmp)
}

fn sample_uuid() -> UuidText {
    UuidText::from(Uuid::parse_str("00112233-4455-6677-8899-aabbccddeeff").unwrap())
}

fn sample_dt() -> DateTimeSecs {
    DateTimeSecs::from(Utc.with_ymd_and_hms(2026, 5, 21, 12, 34, 56).unwrap())
}

#[tokio::test]
async fn user_round_trips() {
    let (db, _tmp) = fresh_sqlite().await;

    db.execute_unprepared(
        "CREATE TABLE users (
            id TEXT PRIMARY KEY,
            username TEXT,
            email TEXT,
            password_hash TEXT,
            oidc_sub TEXT,
            oidc_issuer TEXT,
            role TEXT NOT NULL,
            display_name TEXT,
            avatar_url TEXT,
            last_login_at TEXT,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
    )
    .await
    .unwrap();

    let id = sample_uuid();
    let now = sample_dt();

    let am = users::ActiveModel {
        id: Set(id),
        username: Set(Some("alice".to_string())),
        email: Set(Some("alice@example.com".to_string())),
        password_hash: Set(Some("$2b$12$abcdefghijklmnopqrstuv".to_string())),
        oidc_sub: Set(None),
        oidc_issuer: Set(None),
        role: Set(UserRole::Admin.as_str().to_string()),
        display_name: Set(None),
        avatar_url: Set(None),
        last_login_at: Set(None),
        inserted_at: Set(now),
        updated_at: Set(now),
    };
    let inserted = insert_active_model(am, &db).await.expect("insert user");

    let user = users::Entity::find_by_id(id)
        .one(&db)
        .await
        .expect("find_by_id")
        .expect("user present");

    assert_eq!(user.id, id);
    assert_eq!(user.username.as_deref(), Some("alice"));
    assert_eq!(user.email.as_deref(), Some("alice@example.com"));
    assert_eq!(user.role, "admin");
    assert_eq!(UserRole::parse(&user.role), Some(UserRole::Admin));
    assert_eq!(user.inserted_at, now);
    assert!(user.oidc_sub.is_none());
    // RETURNING-parsed model matches refetched model.
    assert_eq!(inserted, user);
}

#[tokio::test]
async fn api_key_round_trips_with_permissions_array() {
    let (db, _tmp) = fresh_sqlite().await;

    // `permissions` is `text[]` on Postgres, JSON-text on SQLite (per
    // migration 20260223100000_fix_array_columns_for_postgres.exs). Hand-
    // written DDL because `Schema::create_table_from_entity` panics on
    // SQLite for `ColumnType::Array(_)` columns.
    db.execute_unprepared(
        "CREATE TABLE api_keys (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            name TEXT NOT NULL,
            key_hash TEXT NOT NULL,
            key_prefix TEXT,
            permissions TEXT,
            last_used_at TEXT,
            expires_at TEXT,
            revoked_at TEXT,
            inserted_at TEXT NOT NULL
        )",
    )
    .await
    .unwrap();

    let id = sample_uuid();
    let user_id = UuidText::new_v4();
    let now = sample_dt();
    let perms = StringArray::from(vec!["read".to_string(), "write".to_string()]);

    let am = api_keys::ActiveModel {
        id: Set(id),
        user_id: Set(user_id),
        name: Set("ci-bot".to_string()),
        key_hash: Set("$argon2id$v=19$m=65536,t=2,p=1$xxxx$yyyy".to_string()),
        key_prefix: Set(Some("mk_abcd1234".to_string())),
        permissions: Set(Some(perms.clone())),
        last_used_at: Set(None),
        expires_at: Set(None),
        revoked_at: Set(None),
        inserted_at: Set(now),
    };
    insert_active_model(am, &db).await.expect("insert api_key");

    let key = api_keys::Entity::find_by_id(id)
        .one(&db)
        .await
        .expect("find_by_id")
        .expect("api_key present");

    assert_eq!(key.id, id);
    assert_eq!(key.user_id, user_id);
    assert_eq!(
        key.permissions.as_ref().map(|p| p.0.clone()),
        Some(perms.0.clone())
    );
    assert!(key.revoked_at.is_none());
    // VALID_PERMISSIONS constant is exposed for caller-side validation.
    assert!(VALID_PERMISSIONS.contains(&"read"));
}

#[tokio::test]
async fn media_item_round_trips_with_json_metadata() {
    let (db, _tmp) = fresh_sqlite().await;

    db.execute_unprepared(
        "CREATE TABLE media_items (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            title TEXT NOT NULL,
            original_title TEXT,
            year INTEGER,
            tmdb_id INTEGER,
            tvdb_id INTEGER,
            imdb_id TEXT,
            metadata TEXT,
            monitored INTEGER,
            monitoring_preset TEXT,
            category TEXT,
            category_override INTEGER NOT NULL DEFAULT 0,
            seasons_refreshed_at TEXT,
            quality_profile_id TEXT,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
    )
    .await
    .unwrap();

    let id = sample_uuid();
    let now = sample_dt();
    // The entity stores `metadata` as `Option<String>` (the column is
    // a Phoenix custom Ecto JSON-text type — typed as TEXT on disk and
    // marshalled as a JSON string). Serialize the JSON payload here so
    // the round-trip mirrors the production write path.
    let metadata_json = serde_json::json!({"overview": "test movie", "runtime": 120});
    let metadata_string = serde_json::to_string(&metadata_json).unwrap();

    let am = media_items::ActiveModel {
        id: Set(id),
        r#type: Set(MediaKind::Movie.as_str().to_string()),
        title: Set("Inception".to_string()),
        original_title: Set(None),
        year: Set(Some(2010)),
        tmdb_id: Set(Some(27_205)),
        tvdb_id: Set(None),
        imdb_id: Set(None),
        metadata: Set(Some(metadata_string.clone())),
        monitored: Set(Some(true)),
        monitoring_preset: Set(Some(MonitoringPreset::All.as_str().to_string())),
        category: Set(None),
        category_override: Set(false),
        seasons_refreshed_at: Set(None),
        quality_profile_id: Set(None),
        inserted_at: Set(now),
        updated_at: Set(now),
    };
    insert_active_model(am, &db)
        .await
        .expect("insert media_item");

    let item = media_items::Entity::find_by_id(id)
        .one(&db)
        .await
        .expect("find_by_id")
        .expect("media_item present");

    assert_eq!(item.title, "Inception");
    assert_eq!(MediaKind::parse(&item.r#type), Some(MediaKind::Movie));
    assert_eq!(
        item.monitoring_preset
            .as_deref()
            .and_then(MonitoringPreset::parse),
        Some(MonitoringPreset::All)
    );
    let parsed: serde_json::Value = serde_json::from_str(item.metadata.as_ref().unwrap()).unwrap();
    assert_eq!(parsed["overview"].as_str(), Some("test movie"));
    assert_eq!(item.monitored, Some(true));
}

#[tokio::test]
async fn episode_round_trips() {
    let (db, _tmp) = fresh_sqlite().await;

    db.execute_unprepared(
        "CREATE TABLE episodes (
            id TEXT PRIMARY KEY,
            media_item_id TEXT NOT NULL,
            season_number INTEGER NOT NULL,
            episode_number INTEGER NOT NULL,
            title TEXT,
            air_date TEXT,
            metadata TEXT,
            monitored INTEGER,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
    )
    .await
    .unwrap();

    let id = sample_uuid();
    let media_item_id = UuidText::new_v4();
    let now = sample_dt();

    let am = episodes::ActiveModel {
        id: Set(id),
        media_item_id: Set(media_item_id),
        season_number: Set(1),
        episode_number: Set(7),
        title: Set(Some("The One Where ...".to_string())),
        air_date: Set(NaiveDate::from_ymd_opt(2026, 1, 15)),
        metadata: Set(None),
        monitored: Set(Some(true)),
        inserted_at: Set(now),
        updated_at: Set(now),
    };
    insert_active_model(am, &db).await.expect("insert episode");

    let ep = episodes::Entity::find_by_id(id)
        .one(&db)
        .await
        .expect("find_by_id")
        .expect("episode present");

    assert_eq!(ep.media_item_id, media_item_id);
    assert_eq!(ep.season_number, 1);
    assert_eq!(ep.episode_number, 7);
    assert_eq!(ep.air_date, NaiveDate::from_ymd_opt(2026, 1, 15));
}

#[tokio::test]
async fn media_file_round_trips() {
    let (db, _tmp) = fresh_sqlite().await;

    db.execute_unprepared(
        "CREATE TABLE media_files (
            id TEXT PRIMARY KEY,
            media_item_id TEXT,
            episode_id TEXT,
            quality_profile_id TEXT,
            library_path_id TEXT,
            path TEXT,
            relative_path TEXT,
            size INTEGER,
            resolution TEXT,
            codec TEXT,
            hdr_format TEXT,
            audio_codec TEXT,
            bitrate INTEGER,
            verified_at TEXT,
            analyzed_at TEXT,
            analysis_attempts INTEGER NOT NULL DEFAULT 0,
            last_analysis_error TEXT,
            metadata TEXT,
            cover_blob TEXT,
            sprite_blob TEXT,
            vtt_blob TEXT,
            preview_blob TEXT,
            phash TEXT,
            generated_at TEXT,
            trashed_at TEXT,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
    )
    .await
    .unwrap();

    let id = sample_uuid();
    let media_item_id = UuidText::new_v4();
    let library_path_id = UuidText::new_v4();
    let now = sample_dt();
    let metadata_json = serde_json::json!({"container": "mkv", "duration": 7200});
    let metadata_string = serde_json::to_string(&metadata_json).unwrap();

    let am = media_files::ActiveModel {
        id: Set(id),
        media_item_id: Set(Some(media_item_id)),
        episode_id: Set(None),
        quality_profile_id: Set(None),
        library_path_id: Set(Some(library_path_id)),
        path: Set(Some("/movies/Inception (2010)/Inception.mkv".to_string())),
        relative_path: Set(Some("Inception (2010)/Inception.mkv".to_string())),
        size: Set(Some(8_589_934_592)),
        resolution: Set(Some("1080p".to_string())),
        codec: Set(Some("h264".to_string())),
        hdr_format: Set(None),
        audio_codec: Set(None),
        bitrate: Set(Some(15_000_000)),
        verified_at: Set(None),
        analyzed_at: Set(Some(now)),
        analysis_attempts: Set(1),
        last_analysis_error: Set(None),
        metadata: Set(Some(metadata_string.clone())),
        cover_blob: Set(None),
        sprite_blob: Set(None),
        vtt_blob: Set(None),
        preview_blob: Set(None),
        phash: Set(None),
        generated_at: Set(None),
        trashed_at: Set(None),
        inserted_at: Set(now),
        updated_at: Set(now),
    };
    insert_active_model(am, &db)
        .await
        .expect("insert media_file");

    let f = media_files::Entity::find_by_id(id)
        .one(&db)
        .await
        .expect("find_by_id")
        .expect("media_file present");

    assert_eq!(f.media_item_id, Some(media_item_id));
    assert_eq!(f.library_path_id, Some(library_path_id));
    assert_eq!(f.size, Some(8_589_934_592));
    assert_eq!(f.codec.as_deref(), Some("h264"));
    assert_eq!(f.analyzed_at, Some(now));
    assert_eq!(f.analysis_attempts, 1);
    let parsed: serde_json::Value = serde_json::from_str(f.metadata.as_ref().unwrap()).unwrap();
    assert_eq!(parsed["container"].as_str(), Some("mkv"));
    assert!(f.trashed_at.is_none());
}

#[tokio::test]
async fn library_path_round_trips_with_category_paths_map() {
    let (db, _tmp) = fresh_sqlite().await;

    db.execute_unprepared(
        "CREATE TABLE library_paths (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            type TEXT NOT NULL,
            monitored INTEGER,
            scan_interval INTEGER,
            last_scan_at TEXT,
            last_scan_status TEXT,
            last_scan_error TEXT,
            from_env INTEGER NOT NULL DEFAULT 0,
            disabled INTEGER NOT NULL DEFAULT 0,
            category_paths TEXT,
            auto_organize INTEGER,
            auto_import INTEGER,
            write_nfo INTEGER NOT NULL DEFAULT 0,
            auto_rename INTEGER,
            quality_profile_id TEXT,
            updated_by_id TEXT,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
    )
    .await
    .unwrap();

    let id = sample_uuid();
    let now = sample_dt();
    let mut category_paths: HashMap<String, String> = HashMap::new();
    category_paths.insert("anime".into(), "Anime".into());
    category_paths.insert("docs".into(), "Documentaries".into());
    // The entity stores `category_paths` as `JsonMap<serde_json::Value>`.
    // Marshal the typed map through `serde_json::to_value` so the
    // round-trip preserves the same key/value pairs the model expects.
    let category_paths_json = JsonMap(serde_json::to_value(&category_paths).unwrap());

    let am = library_paths::ActiveModel {
        id: Set(id),
        path: Set("/media/tv".to_string()),
        r#type: Set(LibraryPathKind::Series.as_str().to_string()),
        monitored: Set(Some(true)),
        scan_interval: Set(Some(3600)),
        last_scan_at: Set(None),
        last_scan_status: Set(Some(ScanStatus::Success.as_str().to_string())),
        last_scan_error: Set(None),
        from_env: Set(false),
        disabled: Set(false),
        category_paths: Set(Some(category_paths_json)),
        auto_organize: Set(Some(true)),
        auto_import: Set(Some(true)),
        write_nfo: Set(true),
        auto_rename: Set(Some(true)),
        quality_profile_id: Set(None),
        updated_by_id: Set(None),
        inserted_at: Set(now),
        updated_at: Set(now),
    };
    insert_active_model(am, &db)
        .await
        .expect("insert library_path");

    let lp = library_paths::Entity::find_by_id(id)
        .one(&db)
        .await
        .expect("find_by_id")
        .expect("library_path present");

    assert_eq!(lp.path, "/media/tv");
    assert_eq!(
        LibraryPathKind::parse(&lp.r#type),
        Some(LibraryPathKind::Series)
    );
    assert_eq!(
        lp.last_scan_status.as_deref().and_then(ScanStatus::parse),
        Some(ScanStatus::Success)
    );
    let recovered: HashMap<String, String> =
        serde_json::from_value(lp.category_paths.as_ref().unwrap().0.clone()).unwrap();
    assert_eq!(recovered, category_paths);
    assert_eq!(lp.auto_organize, Some(true));
    assert!(lp.write_nfo);
}

#[tokio::test]
async fn subtitle_round_trips() {
    let (db, _tmp) = fresh_sqlite().await;

    db.execute_unprepared(
        "CREATE TABLE subtitles (
            id TEXT PRIMARY KEY,
            media_file_id TEXT NOT NULL,
            language TEXT NOT NULL,
            provider TEXT NOT NULL,
            subtitle_hash TEXT NOT NULL,
            file_path TEXT NOT NULL,
            sync_offset INTEGER,
            format TEXT NOT NULL,
            rating REAL,
            download_count INTEGER,
            hearing_impaired INTEGER NOT NULL DEFAULT 0,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
    )
    .await
    .unwrap();

    let id = sample_uuid();
    let media_file_id = UuidText::new_v4();
    let now = sample_dt();

    let am = subtitles::ActiveModel {
        id: Set(id),
        media_file_id: Set(media_file_id),
        language: Set("en".to_string()),
        provider: Set("opensubtitles".to_string()),
        subtitle_hash: Set("deadbeefcafebabe".to_string()),
        file_path: Set("/library/movies/Inception/Inception.en.srt".to_string()),
        sync_offset: Set(Some(0)),
        format: Set("srt".to_string()),
        rating: Set(Some(9.4)),
        download_count: Set(Some(123)),
        hearing_impaired: Set(false),
        inserted_at: Set(now),
        updated_at: Set(now),
    };
    insert_active_model(am, &db).await.expect("insert subtitle");

    let s = subtitles::Entity::find_by_id(id)
        .one(&db)
        .await
        .expect("find_by_id")
        .expect("subtitle present");

    assert_eq!(s.id, id);
    assert_eq!(s.media_file_id, media_file_id);
    assert_eq!(s.language, "en");
    assert_eq!(s.provider, "opensubtitles");
    assert_eq!(s.format, "srt");
    assert_eq!(s.rating, Some(9.4));
    assert_eq!(s.download_count, Some(123));
    assert!(!s.hearing_impaired);
    assert_eq!(s.sync_offset, Some(0));
    // `mydia_rs_models::Subtitle` exposes the supported-formats constant
    // for caller-side validation; preserve the assertion from the
    // pre-cutover test to keep that surface covered.
    assert_eq!(Subtitle::supported_formats(), &["srt", "ass", "vtt"]);
}
