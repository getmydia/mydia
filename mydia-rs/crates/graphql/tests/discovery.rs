//! U10.b integration tests — discovery resolvers.
//!
//! Covers `recentlyAdded` fully (no auth needed), plus the
//! anonymous-fallback path for `continueWatching`, `upNext`,
//! `favorites`, `unwatched`. The auth-bearing path activates
//! when the U6 follow-up wires `CurrentUser` into the request
//! data slot; this test file expands at that point.

use chrono::Utc;
use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};
use mydia_rs_db::{
    connect_from_config,
    types::{DateTimeSecs, JsonMap, UuidText},
    Db,
};
use mydia_rs_graphql::{build_schema, GraphqlAppState};
use serde_json::json;
use tempfile::TempDir;

const SCHEMA_SQL: &str = include_str!("fixtures/browse_schema.sql");

async fn fresh_schema() -> (Db, TempDir) {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("discovery.db");
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
    let pool = db.as_sqlite().expect("sqlite");
    for stmt in SCHEMA_SQL.split(";\n") {
        let trimmed = stmt.trim();
        if trimmed.is_empty() {
            continue;
        }
        sqlx::query(trimmed).execute(pool).await.expect("schema");
    }
    (db, tmp)
}

async fn seed_movie(
    db: &Db,
    title: &str,
    inserted_at: DateTimeSecs,
    extras: Option<serde_json::Value>,
) -> UuidText {
    let pool = db.as_sqlite().unwrap();
    let id = UuidText::new_v4();
    let metadata = JsonMap(extras.unwrap_or_else(|| json!({})));
    sqlx::query(
        "INSERT INTO media_items (id, type, title, year, tmdb_id, metadata,
            monitored, monitoring_preset, category_override, inserted_at, updated_at)
         VALUES (?, 'movie', ?, 2020, 1, ?, 1, 'all', 0, ?, ?)",
    )
    .bind(id)
    .bind(title)
    .bind(metadata)
    .bind(inserted_at)
    .bind(inserted_at)
    .execute(pool)
    .await
    .expect("seed movie");
    // Seed media file so has_files filter accepts.
    let file_id = UuidText::new_v4();
    sqlx::query(
        "INSERT INTO media_files (id, media_item_id, analysis_attempts, inserted_at, updated_at)
         VALUES (?, ?, 0, ?, ?)",
    )
    .bind(file_id)
    .bind(id)
    .bind(inserted_at)
    .bind(inserted_at)
    .execute(pool)
    .await
    .unwrap();
    id
}

fn now_minus_days(days: i64) -> DateTimeSecs {
    DateTimeSecs::from(Utc::now() - chrono::Duration::days(days))
}

#[tokio::test]
async fn recently_added_returns_items_within_30_day_window() {
    let (db, _tmp) = fresh_schema().await;
    let _recent = seed_movie(&db, "Recent", now_minus_days(5), None).await;
    let _old = seed_movie(&db, "Old", now_minus_days(60), None).await;

    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(r"{ recentlyAdded(first: 10) { id type title year addedAt } }")
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let items = data["recentlyAdded"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["title"], "Recent");
    assert_eq!(items[0]["type"], "MOVIE");
    assert!(items[0]["id"].as_str().unwrap().starts_with("movie:"));
}

#[tokio::test]
async fn recently_added_sorts_newest_first() {
    let (db, _tmp) = fresh_schema().await;
    seed_movie(&db, "Older", now_minus_days(20), None).await;
    seed_movie(&db, "Newer", now_minus_days(2), None).await;
    seed_movie(&db, "Middle", now_minus_days(10), None).await;

    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(r"{ recentlyAdded(first: 10) { title } }")
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let titles: Vec<String> = data["recentlyAdded"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["title"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(titles, vec!["Newer", "Middle", "Older"]);
}

#[tokio::test]
async fn recently_added_respects_first_argument() {
    let (db, _tmp) = fresh_schema().await;
    for i in 0..5 {
        seed_movie(&db, &format!("M{i}"), now_minus_days(i + 1), None).await;
    }

    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(r"{ recentlyAdded(first: 2) { title } }")
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let titles: Vec<&str> = data["recentlyAdded"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["title"].as_str().unwrap())
        .collect();
    assert_eq!(titles, vec!["M0", "M1"]); // newest first (M0 = 1 day ago)
}

#[tokio::test]
async fn recently_added_filters_by_type_argument() {
    let (db, _tmp) = fresh_schema().await;
    seed_movie(&db, "Movie 1", now_minus_days(1), None).await;

    let pool = db.as_sqlite().unwrap();
    let show_id = UuidText::new_v4();
    let now = now_minus_days(1);
    sqlx::query(
        "INSERT INTO media_items (id, type, title, year, tmdb_id, metadata,
            monitored, monitoring_preset, category_override, inserted_at, updated_at)
         VALUES (?, 'tv_show', 'Show 1', 2020, 2, '{}', 1, 'all', 0, ?, ?)",
    )
    .bind(show_id)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();
    let file_id = UuidText::new_v4();
    sqlx::query(
        "INSERT INTO media_files (id, media_item_id, analysis_attempts, inserted_at, updated_at)
         VALUES (?, ?, 0, ?, ?)",
    )
    .bind(file_id)
    .bind(show_id)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();

    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(r"{ recentlyAdded(first: 10, types: [MOVIE]) { title type } }")
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let types: Vec<&str> = data["recentlyAdded"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["type"].as_str().unwrap())
        .collect();
    assert!(types.iter().all(|t| *t == "MOVIE"));
}

#[tokio::test]
async fn recently_added_with_both_types_returns_both() {
    let (db, _tmp) = fresh_schema().await;
    seed_movie(&db, "M", now_minus_days(1), None).await;
    let pool = db.as_sqlite().unwrap();
    let show_id = UuidText::new_v4();
    let now = now_minus_days(2);
    sqlx::query(
        "INSERT INTO media_items (id, type, title, year, tmdb_id, metadata,
            monitored, monitoring_preset, category_override, inserted_at, updated_at)
         VALUES (?, 'tv_show', 'S', 2020, 2, '{}', 1, 'all', 0, ?, ?)",
    )
    .bind(show_id)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();
    let file_id = UuidText::new_v4();
    sqlx::query(
        "INSERT INTO media_files (id, media_item_id, analysis_attempts, inserted_at, updated_at)
         VALUES (?, ?, 0, ?, ?)",
    )
    .bind(file_id)
    .bind(show_id)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();

    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(r"{ recentlyAdded(first: 10, types: [MOVIE, TV_SHOW]) { type } }")
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let types: Vec<&str> = data["recentlyAdded"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["type"].as_str().unwrap())
        .collect();
    assert!(types.contains(&"MOVIE"));
    assert!(types.contains(&"TV_SHOW"));
}

#[tokio::test]
async fn recently_added_carries_artwork_when_metadata_has_paths() {
    let (db, _tmp) = fresh_schema().await;
    seed_movie(
        &db,
        "With Art",
        now_minus_days(1),
        Some(json!({"poster_path": "/abc.jpg", "backdrop_path": "/xyz.jpg"})),
    )
    .await;

    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(r"{ recentlyAdded(first: 10) { title artwork { posterUrl backdropUrl } } }")
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let item = &data["recentlyAdded"][0];
    assert_eq!(item["artwork"]["posterUrl"], "/abc.jpg");
    assert_eq!(item["artwork"]["backdropUrl"], "/xyz.jpg");
}

#[tokio::test]
async fn anonymous_continue_watching_returns_empty_list() {
    let (db, _tmp) = fresh_schema().await;
    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(r"{ continueWatching(first: 10) { id } }")
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert!(data["continueWatching"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn anonymous_up_next_returns_empty_list() {
    let (db, _tmp) = fresh_schema().await;
    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(r"{ upNext(first: 10) { progressState } }")
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert!(data["upNext"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn anonymous_favorites_returns_empty_list() {
    let (db, _tmp) = fresh_schema().await;
    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema.execute(r"{ favorites(first: 10) { id } }").await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert!(data["favorites"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn anonymous_unwatched_returns_empty_list() {
    let (db, _tmp) = fresh_schema().await;
    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema.execute(r"{ unwatched(first: 10) { id } }").await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert!(data["unwatched"].as_array().unwrap().is_empty());
}
