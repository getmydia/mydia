// Tests: per-model CREATE TABLE + INSERT/SELECT round-trip fixtures
// are tier-(b) by category — schema setup and raw assertion SQL is the
// only sensible shape for the type-wrapper round-trip suite.
#![allow(clippy::disallowed_methods)]

//! Round-trip integration tests for the first batch of models.
//!
//! Each test:
//!   1. Spins up an in-process `SQLite` pool.
//!   2. `CREATE TABLE` mirroring the columns of the model under test
//!      (subset of the Phoenix schema — the columns this struct exposes).
//!   3. Inserts a Rust-built row through the type wrappers.
//!   4. Reads it back via `sqlx::query_as::<_, Model>` and asserts the
//!      fields round-trip.
//!
//! Postgres round-trip for the underlying type wrappers already lives
//! in `crates/db/tests/postgres_smoke.rs`. Model-level Postgres tests
//! land when the model is first exercised by a resolver.

use std::collections::HashMap;

use chrono::{NaiveDate, TimeZone, Utc};
use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};
use mydia_rs_db::{
    connect_from_config,
    types::{DateTimeSecs, JsonMap, StringArray, UuidText},
    Db,
};
use mydia_rs_models::{
    api_key::VALID_PERMISSIONS,
    library_path::{LibraryPathKind, ScanStatus},
    media_item::{MediaKind, MonitoringPreset},
    user::UserRole,
    ApiKey, Episode, LibraryPath, MediaFile, MediaItem, Subtitle, User,
};
use tempfile::TempDir;
use uuid::Uuid;

async fn fresh_sqlite() -> (Db, TempDir) {
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
    let pool = db.as_sqlite().unwrap();

    sqlx::query(
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
    .execute(pool)
    .await
    .unwrap();

    let id = sample_uuid();
    let now = sample_dt();

    sqlx::query(
        "INSERT INTO users (id, username, email, password_hash, role, inserted_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(id)
    .bind("alice")
    .bind("alice@example.com")
    .bind("$2b$12$abcdefghijklmnopqrstuv")
    .bind(UserRole::Admin.as_str())
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();

    let user: User = sqlx::query_as("SELECT * FROM users WHERE id = ?")
        .bind(id)
        .fetch_one(pool)
        .await
        .unwrap();

    assert_eq!(user.id, id);
    assert_eq!(user.username.as_deref(), Some("alice"));
    assert_eq!(user.email.as_deref(), Some("alice@example.com"));
    assert_eq!(user.role, "admin");
    assert_eq!(user.role(), Some(UserRole::Admin));
    assert_eq!(user.inserted_at, now);
    assert!(user.oidc_sub.is_none());
}

#[tokio::test]
async fn api_key_round_trips_with_permissions_array() {
    let (db, _tmp) = fresh_sqlite().await;
    let pool = db.as_sqlite().unwrap();

    sqlx::query(
        "CREATE TABLE api_keys (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            name TEXT,
            key_hash TEXT,
            key_prefix TEXT,
            permissions TEXT,
            last_used_at TEXT,
            expires_at TEXT,
            revoked_at TEXT,
            inserted_at TEXT NOT NULL
        )",
    )
    .execute(pool)
    .await
    .unwrap();

    let id = sample_uuid();
    let user_id = UuidText::new_v4();
    let now = sample_dt();
    let perms = StringArray::from(vec!["read".into(), "write".into()]);

    sqlx::query(
        "INSERT INTO api_keys (id, user_id, name, key_hash, key_prefix, permissions, inserted_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(id)
    .bind(user_id)
    .bind("ci-bot")
    .bind("$argon2id$v=19$m=65536,t=2,p=1$xxxx$yyyy")
    .bind("mk_abcd1234")
    .bind(perms.clone())
    .bind(now)
    .execute(pool)
    .await
    .unwrap();

    let key: ApiKey = sqlx::query_as("SELECT * FROM api_keys WHERE id = ?")
        .bind(id)
        .fetch_one(pool)
        .await
        .unwrap();

    assert_eq!(key.id, id);
    assert_eq!(key.user_id, user_id);
    assert_eq!(
        key.permissions.as_ref().map(|p| p.0.clone()),
        Some(perms.0.clone())
    );
    assert!(!key.is_revoked());
    // VALID_PERMISSIONS constant is exposed for caller-side validation.
    assert!(VALID_PERMISSIONS.contains(&"read"));
}

#[tokio::test]
async fn media_item_round_trips_with_json_metadata() {
    let (db, _tmp) = fresh_sqlite().await;
    let pool = db.as_sqlite().unwrap();

    sqlx::query(
        "CREATE TABLE media_items (
            id TEXT PRIMARY KEY,
            type TEXT,
            title TEXT,
            original_title TEXT,
            year INTEGER,
            tmdb_id INTEGER,
            tvdb_id INTEGER,
            imdb_id TEXT,
            metadata TEXT,
            monitored INTEGER NOT NULL DEFAULT 1,
            monitoring_preset TEXT NOT NULL DEFAULT 'all',
            category TEXT,
            category_override INTEGER NOT NULL DEFAULT 0,
            seasons_refreshed_at TEXT,
            quality_profile_id TEXT,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
    )
    .execute(pool)
    .await
    .unwrap();

    let id = sample_uuid();
    let now = sample_dt();
    let metadata = JsonMap(serde_json::json!({"overview": "test movie", "runtime": 120}));

    sqlx::query(
        "INSERT INTO media_items
            (id, type, title, year, tmdb_id, metadata, monitored, monitoring_preset,
             category_override, inserted_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(id)
    .bind(MediaKind::Movie.as_str())
    .bind("Inception")
    .bind(2010_i32)
    .bind(27_205_i64)
    .bind(metadata)
    .bind(true)
    .bind(MonitoringPreset::All.as_str())
    .bind(false)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();

    let item: MediaItem = sqlx::query_as("SELECT * FROM media_items WHERE id = ?")
        .bind(id)
        .fetch_one(pool)
        .await
        .unwrap();

    assert_eq!(item.title.as_deref(), Some("Inception"));
    assert_eq!(item.kind(), Some(MediaKind::Movie));
    assert_eq!(item.monitoring_preset(), Some(MonitoringPreset::All));
    assert_eq!(
        item.metadata.unwrap().0["overview"].as_str(),
        Some("test movie")
    );
    assert!(item.monitored);
}

#[tokio::test]
async fn episode_round_trips() {
    let (db, _tmp) = fresh_sqlite().await;
    let pool = db.as_sqlite().unwrap();

    sqlx::query(
        "CREATE TABLE episodes (
            id TEXT PRIMARY KEY,
            media_item_id TEXT NOT NULL,
            season_number INTEGER,
            episode_number INTEGER,
            title TEXT,
            air_date TEXT,
            metadata TEXT,
            monitored INTEGER NOT NULL DEFAULT 1,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
    )
    .execute(pool)
    .await
    .unwrap();

    let id = sample_uuid();
    let media_item_id = UuidText::new_v4();
    let now = sample_dt();

    sqlx::query(
        "INSERT INTO episodes
            (id, media_item_id, season_number, episode_number, title, air_date,
             monitored, inserted_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(id)
    .bind(media_item_id)
    .bind(1_i32)
    .bind(7_i32)
    .bind("The One Where ...")
    .bind(NaiveDate::from_ymd_opt(2026, 1, 15).unwrap())
    .bind(true)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();

    let ep: Episode = sqlx::query_as("SELECT * FROM episodes WHERE id = ?")
        .bind(id)
        .fetch_one(pool)
        .await
        .unwrap();

    assert_eq!(ep.media_item_id, media_item_id);
    assert_eq!(ep.season_number, Some(1));
    assert_eq!(ep.episode_number, Some(7));
    assert_eq!(ep.air_date, NaiveDate::from_ymd_opt(2026, 1, 15));
}

#[tokio::test]
async fn media_file_round_trips() {
    let (db, _tmp) = fresh_sqlite().await;
    let pool = db.as_sqlite().unwrap();

    sqlx::query(
        "CREATE TABLE media_files (
            id TEXT PRIMARY KEY,
            media_item_id TEXT NOT NULL,
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
    .execute(pool)
    .await
    .unwrap();

    let id = sample_uuid();
    let media_item_id = UuidText::new_v4();
    let library_path_id = UuidText::new_v4();
    let now = sample_dt();
    let metadata = JsonMap(serde_json::json!({"container": "mkv", "duration": 7200}));

    sqlx::query(
        "INSERT INTO media_files
            (id, media_item_id, library_path_id, path, relative_path, size,
             resolution, codec, bitrate, analyzed_at, analysis_attempts,
             metadata, inserted_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(id)
    .bind(media_item_id)
    .bind(library_path_id)
    .bind("/movies/Inception (2010)/Inception.mkv")
    .bind("Inception (2010)/Inception.mkv")
    .bind(8_589_934_592_i64)
    .bind("1080p")
    .bind("h264")
    .bind(15_000_000_i64)
    .bind(now)
    .bind(1_i32)
    .bind(metadata)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();

    let f: MediaFile = sqlx::query_as("SELECT * FROM media_files WHERE id = ?")
        .bind(id)
        .fetch_one(pool)
        .await
        .unwrap();

    assert_eq!(f.media_item_id, media_item_id);
    assert_eq!(f.library_path_id, Some(library_path_id));
    assert_eq!(f.size, Some(8_589_934_592));
    assert_eq!(f.codec.as_deref(), Some("h264"));
    assert_eq!(f.analyzed_at, Some(now));
    assert_eq!(f.analysis_attempts, 1);
    assert_eq!(f.metadata.unwrap().0["container"].as_str(), Some("mkv"));
    assert!(f.trashed_at.is_none());
}

#[tokio::test]
async fn library_path_round_trips_with_category_paths_map() {
    let (db, _tmp) = fresh_sqlite().await;
    let pool = db.as_sqlite().unwrap();

    sqlx::query(
        "CREATE TABLE library_paths (
            id TEXT PRIMARY KEY,
            path TEXT,
            type TEXT,
            monitored INTEGER NOT NULL DEFAULT 1,
            scan_interval INTEGER NOT NULL DEFAULT 3600,
            last_scan_at TEXT,
            last_scan_status TEXT,
            last_scan_error TEXT,
            from_env INTEGER NOT NULL DEFAULT 0,
            disabled INTEGER NOT NULL DEFAULT 0,
            category_paths TEXT NOT NULL DEFAULT '{}',
            auto_organize INTEGER NOT NULL DEFAULT 0,
            auto_import INTEGER NOT NULL DEFAULT 0,
            write_nfo INTEGER NOT NULL DEFAULT 0,
            auto_rename INTEGER NOT NULL DEFAULT 1,
            quality_profile_id TEXT,
            updated_by_id TEXT,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
    )
    .execute(pool)
    .await
    .unwrap();

    let id = sample_uuid();
    let now = sample_dt();
    let mut category_paths = HashMap::new();
    category_paths.insert("anime".into(), "Anime".into());
    category_paths.insert("docs".into(), "Documentaries".into());
    let category_paths_json = JsonMap(category_paths.clone());

    sqlx::query(
        "INSERT INTO library_paths
            (id, path, type, monitored, scan_interval, last_scan_status,
             from_env, disabled, category_paths, auto_organize, auto_import,
             write_nfo, auto_rename, inserted_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(id)
    .bind("/media/tv")
    .bind(LibraryPathKind::Series.as_str())
    .bind(true)
    .bind(3600_i32)
    .bind(ScanStatus::Success.as_str())
    .bind(false)
    .bind(false)
    .bind(category_paths_json)
    .bind(true)
    .bind(true)
    .bind(true)
    .bind(true)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();

    let lp: LibraryPath = sqlx::query_as("SELECT * FROM library_paths WHERE id = ?")
        .bind(id)
        .fetch_one(pool)
        .await
        .unwrap();

    assert_eq!(lp.path.as_deref(), Some("/media/tv"));
    assert_eq!(lp.kind(), Some(LibraryPathKind::Series));
    assert_eq!(lp.scan_status(), Some(ScanStatus::Success));
    assert_eq!(lp.category_paths.0, category_paths);
    assert!(lp.auto_organize);
    assert!(lp.write_nfo);
}

#[tokio::test]
async fn subtitle_round_trips() {
    let (db, _tmp) = fresh_sqlite().await;
    let pool = db.as_sqlite().unwrap();

    sqlx::query(
        "CREATE TABLE subtitles (
            id TEXT PRIMARY KEY,
            media_file_id TEXT NOT NULL,
            language TEXT NOT NULL,
            provider TEXT NOT NULL,
            subtitle_hash TEXT NOT NULL,
            file_path TEXT NOT NULL,
            sync_offset INTEGER NOT NULL DEFAULT 0,
            format TEXT NOT NULL,
            rating REAL,
            download_count INTEGER,
            hearing_impaired INTEGER NOT NULL DEFAULT 0,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
    )
    .execute(pool)
    .await
    .unwrap();

    let id = sample_uuid();
    let media_file_id = UuidText::new_v4();
    let now = sample_dt();

    sqlx::query(
        "INSERT INTO subtitles
            (id, media_file_id, language, provider, subtitle_hash, file_path,
             sync_offset, format, rating, download_count, hearing_impaired,
             inserted_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(id)
    .bind(media_file_id)
    .bind("en")
    .bind("opensubtitles")
    .bind("deadbeefcafebabe")
    .bind("/library/movies/Inception/Inception.en.srt")
    .bind(0_i32)
    .bind("srt")
    .bind(9.4_f64)
    .bind(123_i32)
    .bind(false)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();

    let s: Subtitle = sqlx::query_as("SELECT * FROM subtitles WHERE id = ?")
        .bind(id)
        .fetch_one(pool)
        .await
        .unwrap();

    assert_eq!(s.id, id);
    assert_eq!(s.media_file_id, media_file_id);
    assert_eq!(s.language, "en");
    assert_eq!(s.provider, "opensubtitles");
    assert_eq!(s.format, "srt");
    assert_eq!(s.rating, Some(9.4));
    assert_eq!(s.download_count, Some(123));
    assert!(!s.hearing_impaired);
    assert_eq!(s.sync_offset, 0);
    assert_eq!(Subtitle::supported_formats(), &["srt", "ass", "vtt"]);
}
