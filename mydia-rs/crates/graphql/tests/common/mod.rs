//! Shared test helpers for the graphql crate.
//!
//! Each per-test-file `fresh_schema` builds a fresh in-memory `SQLite`
//! `DatabaseConnection`, creates the entity tables it needs via
//! `Schema::create_table_from_entity`, and returns the open
//! connection. Foreign-key enforcement stays off — many of the
//! entities the resolvers touch (`media_items`, `episodes`,
//! `media_files`, `library_paths`, `collections`, ...) reference
//! sibling tables the test never creates (`quality_profiles`,
//! `users`, ...).

#![allow(dead_code)]

use std::sync::atomic::{AtomicI32, Ordering};

use chrono::{TimeZone, Utc};
use mydia_rs_db::insert_active_model;
use mydia_rs_db::types::{DateTimeSecs, JsonMap, StringArray, UuidText};
use mydia_rs_entities::{
    api_keys, collection_items, collections, episodes, library_paths, media_files, media_items,
    playback_progress, users,
};
use sea_orm::{ActiveValue, ConnectionTrait, Database, DatabaseConnection, Schema, Set};

/// Build a fresh in-memory `SQLite` `DatabaseConnection` with FK
/// enforcement disabled. The caller-supplied closure attaches the
/// tables the test needs.
pub async fn fresh_db_with<F>(create_entities: F) -> DatabaseConnection
where
    F: FnOnce(&DatabaseConnection, &Schema) -> Vec<sea_orm::sea_query::TableCreateStatement>,
{
    let db = Database::connect("sqlite::memory:")
        .await
        .expect("connect in-memory sqlite");
    db.execute_unprepared("PRAGMA foreign_keys = OFF")
        .await
        .expect("disable fk");
    let backend = db.get_database_backend();
    let schema = Schema::new(backend);
    let statements = create_entities(&db, &schema);
    for stmt in statements {
        db.execute(&stmt).await.expect("create table");
    }
    db
}

/// Build a fresh `SQLite` DB with the full browse-related schema:
/// `media_items`, `episodes`, `media_files`, `library_paths`.
pub async fn fresh_browse_db() -> DatabaseConnection {
    fresh_db_with(|_, schema| {
        vec![
            schema.create_table_from_entity(media_items::Entity),
            schema.create_table_from_entity(episodes::Entity),
            schema.create_table_from_entity(media_files::Entity),
            schema.create_table_from_entity(library_paths::Entity),
        ]
    })
    .await
}

/// Build a fresh `SQLite` DB with the u11/playback schema:
/// `media_items`, `episodes`, `media_files`, `users`,
/// `playback_progress`, `collections`, `collection_items`.
pub async fn fresh_playback_db() -> DatabaseConnection {
    fresh_db_with(|_, schema| {
        vec![
            schema.create_table_from_entity(media_items::Entity),
            schema.create_table_from_entity(episodes::Entity),
            schema.create_table_from_entity(media_files::Entity),
            schema.create_table_from_entity(users::Entity),
            schema.create_table_from_entity(playback_progress::Entity),
            schema.create_table_from_entity(collections::Entity),
            schema.create_table_from_entity(collection_items::Entity),
        ]
    })
    .await
}

/// Build a fresh `SQLite` DB with the u14 schema: `users`, `api_keys`,
/// `collections`, `collection_items`, `media_items`.
///
/// `api_keys.permissions` is `text[]` on Postgres; `Schema::create_table_from_entity`
/// emits the Array column type unconditionally, which `SQLite` does not support.
/// The wrapper marshals as JSON-text on `SQLite`, so we issue the
/// equivalent `CREATE TABLE api_keys` DDL by hand using a plain `TEXT`
/// column for `permissions`. This mirrors the Phoenix migration on the
/// `SQLite` side and keeps the wrapper round-trip working.
pub async fn fresh_u14_db() -> DatabaseConnection {
    let db = Database::connect("sqlite::memory:")
        .await
        .expect("connect in-memory sqlite");
    db.execute_unprepared("PRAGMA foreign_keys = OFF")
        .await
        .expect("disable fk");
    let backend = db.get_database_backend();
    let schema = Schema::new(backend);
    for stmt in [
        schema.create_table_from_entity(users::Entity),
        schema.create_table_from_entity(collections::Entity),
        schema.create_table_from_entity(collection_items::Entity),
        schema.create_table_from_entity(media_items::Entity),
    ] {
        db.execute(&stmt).await.expect("create table");
    }
    // Manual DDL for api_keys — Phoenix's SQLite shape uses TEXT for the
    // `permissions` array (Ecto serializes the `:array, :string` as JSON-text).
    db.execute_unprepared(
        "CREATE TABLE api_keys (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            name TEXT NOT NULL,
            key_hash TEXT NOT NULL UNIQUE,
            last_used_at TEXT,
            expires_at TEXT,
            inserted_at TEXT NOT NULL,
            key_prefix TEXT,
            revoked_at TEXT,
            permissions TEXT
        )",
    )
    .await
    .expect("create api_keys table");
    db
}

pub fn sample_dt(year: i32, month: u32, day: u32) -> DateTimeSecs {
    DateTimeSecs::from(Utc.with_ymd_and_hms(year, month, day, 0, 0, 0).unwrap())
}

/// Allocate a unique `tmdb_id` value. `media_items.tmdb_id` is UNIQUE on
/// the entity (Phoenix migration), so seeded rows can't share IDs.
pub fn next_tmdb_id() -> i32 {
    static COUNTER: AtomicI32 = AtomicI32::new(1);
    COUNTER.fetch_add(1, Ordering::Relaxed)
}

pub async fn seed_movie(
    db: &DatabaseConnection,
    id: UuidText,
    title: &str,
    year: i32,
    vote_average: f64,
    inserted_at: DateTimeSecs,
) {
    let metadata = serde_json::json!({ "vote_average": vote_average });
    let metadata_text = serde_json::to_string(&metadata).unwrap();
    let am = media_items::ActiveModel {
        id: Set(id),
        r#type: Set("movie".to_owned()),
        title: Set(title.to_owned()),
        original_title: Set(None),
        year: Set(Some(year)),
        tmdb_id: Set(Some(next_tmdb_id())),
        imdb_id: Set(None),
        metadata: Set(Some(metadata_text)),
        monitored: Set(Some(true)),
        inserted_at: Set(inserted_at),
        updated_at: Set(inserted_at),
        quality_profile_id: Set(None),
        category: Set(None),
        category_override: Set(false),
        monitoring_preset: Set(Some("all".to_owned())),
        seasons_refreshed_at: Set(None),
        tvdb_id: Set(None),
    };
    insert_active_model(am, db).await.expect("seed movie");

    // Seed at least one media file so the `has_files: true` filter
    // doesn't exclude this movie.
    let file_id = UuidText::new_v4();
    let file_am = media_files::ActiveModel {
        id: Set(file_id),
        media_item_id: Set(Some(id)),
        episode_id: Set(None),
        path: Set(None),
        size: Set(None),
        quality_profile_id: Set(None),
        resolution: Set(None),
        codec: Set(None),
        hdr_format: Set(None),
        audio_codec: Set(None),
        bitrate: Set(None),
        verified_at: Set(None),
        metadata: Set(None),
        inserted_at: Set(inserted_at),
        updated_at: Set(inserted_at),
        library_path_id: Set(None),
        relative_path: Set(None),
        cover_blob: Set(None),
        sprite_blob: Set(None),
        vtt_blob: Set(None),
        preview_blob: Set(None),
        phash: Set(None),
        generated_at: Set(None),
        trashed_at: Set(None),
        analyzed_at: Set(None),
        analysis_attempts: Set(0),
        last_analysis_error: Set(None),
    };
    insert_active_model(file_am, db)
        .await
        .expect("seed media file");
}

pub async fn seed_movie_no_file(
    db: &DatabaseConnection,
    id: UuidText,
    title: &str,
    year: Option<i32>,
    metadata: serde_json::Value,
    inserted_at: DateTimeSecs,
) {
    let metadata_text = serde_json::to_string(&metadata).unwrap();
    let am = media_items::ActiveModel {
        id: Set(id),
        r#type: Set("movie".to_owned()),
        title: Set(title.to_owned()),
        original_title: Set(None),
        year: Set(year),
        tmdb_id: Set(year.map(|_| next_tmdb_id())),
        imdb_id: Set(None),
        metadata: Set(Some(metadata_text)),
        monitored: Set(Some(true)),
        inserted_at: Set(inserted_at),
        updated_at: Set(inserted_at),
        quality_profile_id: Set(None),
        category: Set(None),
        category_override: Set(false),
        monitoring_preset: Set(Some("all".to_owned())),
        seasons_refreshed_at: Set(None),
        tvdb_id: Set(None),
    };
    insert_active_model(am, db).await.expect("seed movie");
}

pub async fn seed_tv_show(
    db: &DatabaseConnection,
    id: UuidText,
    title: &str,
    year: i32,
    inserted_at: DateTimeSecs,
) {
    let am = media_items::ActiveModel {
        id: Set(id),
        r#type: Set("tv_show".to_owned()),
        title: Set(title.to_owned()),
        original_title: Set(None),
        year: Set(Some(year)),
        tmdb_id: Set(Some(next_tmdb_id())),
        imdb_id: Set(None),
        metadata: Set(Some("{}".to_owned())),
        monitored: Set(Some(true)),
        inserted_at: Set(inserted_at),
        updated_at: Set(inserted_at),
        quality_profile_id: Set(None),
        category: Set(None),
        category_override: Set(false),
        monitoring_preset: Set(Some("all".to_owned())),
        seasons_refreshed_at: Set(None),
        tvdb_id: Set(None),
    };
    insert_active_model(am, db).await.expect("seed tv_show");
}

pub async fn seed_episode(
    db: &DatabaseConnection,
    id: UuidText,
    media_item_id: UuidText,
    season_number: i32,
    episode_number: i32,
    title: &str,
    inserted_at: DateTimeSecs,
) {
    let am = episodes::ActiveModel {
        id: Set(id),
        media_item_id: Set(media_item_id),
        season_number: Set(season_number),
        episode_number: Set(episode_number),
        title: Set(Some(title.to_owned())),
        air_date: Set(None),
        metadata: Set(None),
        monitored: Set(Some(true)),
        inserted_at: Set(inserted_at),
        updated_at: Set(inserted_at),
    };
    insert_active_model(am, db).await.expect("seed episode");
}

pub async fn seed_library_path(
    db: &DatabaseConnection,
    id: UuidText,
    path: &str,
    kind: &str,
    inserted_at: DateTimeSecs,
) {
    let category_paths = JsonMap(serde_json::json!({}));
    let am = library_paths::ActiveModel {
        id: Set(id),
        path: Set(path.to_owned()),
        r#type: Set(kind.to_owned()),
        monitored: Set(Some(true)),
        scan_interval: Set(Some(3600)),
        last_scan_at: Set(None),
        last_scan_status: Set(None),
        last_scan_error: Set(None),
        quality_profile_id: Set(None),
        updated_by_id: Set(None),
        inserted_at: Set(inserted_at),
        updated_at: Set(inserted_at),
        from_env: Set(false),
        disabled: Set(false),
        category_paths: Set(Some(category_paths)),
        auto_organize: Set(Some(false)),
        auto_import: Set(Some(false)),
        auto_rename: Set(Some(true)),
        write_nfo: Set(false),
    };
    insert_active_model(am, db)
        .await
        .expect("seed library path");
}

pub async fn seed_user(db: &DatabaseConnection, id: UuidText, username: &str) {
    let now = DateTimeSecs::from(Utc::now());
    let am = users::ActiveModel {
        id: Set(id),
        username: Set(Some(username.to_owned())),
        email: Set(None),
        password_hash: Set(None),
        oidc_sub: Set(None),
        oidc_issuer: Set(None),
        role: Set("user".to_owned()),
        display_name: Set(None),
        avatar_url: Set(None),
        last_login_at: Set(None),
        inserted_at: Set(now),
        updated_at: Set(now),
    };
    insert_active_model(am, db).await.expect("seed user");
}

pub async fn seed_user_with_password(
    db: &DatabaseConnection,
    id: UuidText,
    username: &str,
    email: Option<&str>,
    password_hash: &str,
) {
    let now = DateTimeSecs::from(Utc::now());
    let am = users::ActiveModel {
        id: Set(id),
        username: Set(Some(username.to_owned())),
        email: Set(email.map(std::borrow::ToOwned::to_owned)),
        password_hash: Set(Some(password_hash.to_owned())),
        oidc_sub: Set(None),
        oidc_issuer: Set(None),
        role: Set("user".to_owned()),
        display_name: Set(None),
        avatar_url: Set(None),
        last_login_at: Set(None),
        inserted_at: Set(now),
        updated_at: Set(now),
    };
    insert_active_model(am, db).await.expect("seed user");
}

pub async fn seed_movie_with_metadata(
    db: &DatabaseConnection,
    id: UuidText,
    title: &str,
    metadata: serde_json::Value,
) {
    let now = DateTimeSecs::from(Utc::now());
    let metadata_text = serde_json::to_string(&metadata).unwrap();
    let am = media_items::ActiveModel {
        id: Set(id),
        r#type: Set("movie".to_owned()),
        title: Set(title.to_owned()),
        original_title: Set(None),
        year: Set(Some(2020)),
        tmdb_id: Set(Some(next_tmdb_id())),
        imdb_id: Set(None),
        metadata: Set(Some(metadata_text)),
        monitored: Set(Some(true)),
        inserted_at: Set(now),
        updated_at: Set(now),
        quality_profile_id: Set(None),
        category: Set(None),
        category_override: Set(false),
        monitoring_preset: Set(Some("all".to_owned())),
        seasons_refreshed_at: Set(None),
        tvdb_id: Set(None),
    };
    insert_active_model(am, db).await.expect("seed movie");
}

pub async fn seed_tv_show_simple(db: &DatabaseConnection, id: UuidText, title: &str) {
    let now = DateTimeSecs::from(Utc::now());
    let am = media_items::ActiveModel {
        id: Set(id),
        r#type: Set("tv_show".to_owned()),
        title: Set(title.to_owned()),
        original_title: Set(None),
        year: Set(Some(2020)),
        tmdb_id: Set(Some(next_tmdb_id())),
        imdb_id: Set(None),
        metadata: Set(Some("{}".to_owned())),
        monitored: Set(Some(true)),
        inserted_at: Set(now),
        updated_at: Set(now),
        quality_profile_id: Set(None),
        category: Set(None),
        category_override: Set(false),
        monitoring_preset: Set(Some("all".to_owned())),
        seasons_refreshed_at: Set(None),
        tvdb_id: Set(None),
    };
    insert_active_model(am, db).await.expect("seed tv_show");
}

pub async fn seed_episode_simple(
    db: &DatabaseConnection,
    id: UuidText,
    media_item_id: UuidText,
    season_number: i32,
    episode_number: i32,
    title: &str,
) {
    let now = DateTimeSecs::from(Utc::now());
    seed_episode(
        db,
        id,
        media_item_id,
        season_number,
        episode_number,
        title,
        now,
    )
    .await;
}

pub async fn seed_media_file_with_metadata(
    db: &DatabaseConnection,
    id: UuidText,
    media_item_id: Option<UuidText>,
    episode_id: Option<UuidText>,
    duration: f64,
) {
    let now = DateTimeSecs::from(Utc::now());
    let metadata = serde_json::json!({"duration": duration});
    let metadata_text = serde_json::to_string(&metadata).unwrap();
    let am = media_files::ActiveModel {
        id: Set(id),
        media_item_id: Set(media_item_id),
        episode_id: Set(episode_id),
        path: Set(None),
        size: Set(None),
        quality_profile_id: Set(None),
        resolution: Set(Some("1080p".to_owned())),
        codec: Set(Some("h264".to_owned())),
        hdr_format: Set(None),
        audio_codec: Set(Some("aac".to_owned())),
        bitrate: Set(Some(5_000_000)),
        verified_at: Set(None),
        metadata: Set(Some(metadata_text)),
        inserted_at: Set(now),
        updated_at: Set(now),
        library_path_id: Set(None),
        relative_path: Set(None),
        cover_blob: Set(None),
        sprite_blob: Set(None),
        vtt_blob: Set(None),
        preview_blob: Set(None),
        phash: Set(None),
        generated_at: Set(None),
        trashed_at: Set(None),
        analyzed_at: Set(None),
        analysis_attempts: Set(0),
        last_analysis_error: Set(None),
    };
    insert_active_model(am, db).await.expect("seed media file");
}

pub async fn seed_api_key(
    db: &DatabaseConnection,
    id: UuidText,
    user_id: UuidText,
    name: &str,
    key_hash: &str,
    key_prefix: &str,
    permissions: Vec<String>,
) {
    let now = DateTimeSecs::from(Utc::now());
    let am = api_keys::ActiveModel {
        id: Set(id),
        user_id: Set(user_id),
        name: Set(name.to_owned()),
        key_hash: Set(key_hash.to_owned()),
        key_prefix: Set(Some(key_prefix.to_owned())),
        permissions: Set(Some(StringArray(permissions))),
        last_used_at: ActiveValue::NotSet,
        expires_at: Set(None),
        revoked_at: Set(None),
        inserted_at: Set(now),
    };
    insert_active_model(am, db).await.expect("seed api key");
}

pub async fn seed_collection(
    db: &DatabaseConnection,
    id: UuidText,
    user_id: UuidText,
    name: &str,
    kind: &str,
    is_system: bool,
    position: i32,
) {
    let now = DateTimeSecs::from(Utc::now());
    let am = collections::ActiveModel {
        id: Set(id),
        user_id: Set(user_id),
        name: Set(name.to_owned()),
        description: Set(None),
        r#type: Set(kind.to_owned()),
        poster_path: Set(None),
        sort_order: Set("position".to_owned()),
        smart_rules: Set(None),
        visibility: Set("private".to_owned()),
        is_system: Set(is_system),
        position: Set(position),
        inserted_at: Set(now),
        updated_at: Set(now),
    };
    insert_active_model(am, db).await.expect("seed collection");
}

pub async fn seed_collection_item(
    db: &DatabaseConnection,
    id: UuidText,
    collection_id: UuidText,
    media_item_id: UuidText,
    position: i32,
) {
    let now = DateTimeSecs::from(Utc::now());
    let am = collection_items::ActiveModel {
        id: Set(id),
        collection_id: Set(collection_id),
        media_item_id: Set(media_item_id),
        position: Set(position),
        inserted_at: Set(now),
    };
    insert_active_model(am, db)
        .await
        .expect("seed collection item");
}

/// Build a graphql schema bound to `db`.
pub fn build_test_schema(db: DatabaseConnection) -> mydia_rs_graphql::MydiaSchema {
    mydia_rs_graphql::build_schema(mydia_rs_graphql::GraphqlAppState::new(db))
}
