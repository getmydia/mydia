//! U10.b integration tests — discovery resolvers.
//!
//! Covers `recentlyAdded` fully (no auth needed), plus the
//! anonymous-fallback path for `continueWatching`, `upNext`,
//! `favorites`, `unwatched`. The auth-bearing path activates
//! when the U6 follow-up wires `CurrentUser` into the request
//! data slot; this test file expands at that point.

mod common;

use chrono::Utc;
use mydia_rs_db::insert_active_model;
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_entities::{media_files, media_items};
use sea_orm::{DatabaseConnection, Set};
use serde_json::json;

use common::{build_test_schema, fresh_browse_db};

async fn seed_movie(
    db: &DatabaseConnection,
    title: &str,
    inserted_at: DateTimeSecs,
    extras: Option<serde_json::Value>,
) -> UuidText {
    use std::sync::atomic::{AtomicI32, Ordering};
    static TMDB_COUNTER: AtomicI32 = AtomicI32::new(1);
    let tmdb = TMDB_COUNTER.fetch_add(1, Ordering::Relaxed);
    let id = UuidText::new_v4();
    let metadata = extras.unwrap_or_else(|| json!({}));
    let metadata_text = serde_json::to_string(&metadata).unwrap();
    let am = media_items::ActiveModel {
        id: Set(id),
        r#type: Set("movie".to_owned()),
        title: Set(title.to_owned()),
        original_title: Set(None),
        year: Set(Some(2020)),
        tmdb_id: Set(Some(tmdb)),
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

    // Seed media file so has_files filter accepts.
    let file_am = media_files::ActiveModel {
        id: Set(UuidText::new_v4()),
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
    id
}

async fn seed_tv_show(
    db: &DatabaseConnection,
    title: &str,
    inserted_at: DateTimeSecs,
) -> UuidText {
    use std::sync::atomic::{AtomicI32, Ordering};
    static TVDB_COUNTER: AtomicI32 = AtomicI32::new(10_000);
    let tmdb = TVDB_COUNTER.fetch_add(1, Ordering::Relaxed);
    let id = UuidText::new_v4();
    let am = media_items::ActiveModel {
        id: Set(id),
        r#type: Set("tv_show".to_owned()),
        title: Set(title.to_owned()),
        original_title: Set(None),
        year: Set(Some(2020)),
        tmdb_id: Set(Some(tmdb)),
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
    // associated file
    let file_am = media_files::ActiveModel {
        id: Set(UuidText::new_v4()),
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
    id
}

fn now_minus_days(days: i64) -> DateTimeSecs {
    DateTimeSecs::from(Utc::now() - chrono::Duration::days(days))
}

#[tokio::test]
async fn recently_added_returns_items_within_30_day_window() {
    let db = fresh_browse_db().await;
    let _recent = seed_movie(&db, "Recent", now_minus_days(5), None).await;
    let _old = seed_movie(&db, "Old", now_minus_days(60), None).await;

    let schema = build_test_schema(db);
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
    let db = fresh_browse_db().await;
    seed_movie(&db, "Older", now_minus_days(20), None).await;
    seed_movie(&db, "Newer", now_minus_days(2), None).await;
    seed_movie(&db, "Middle", now_minus_days(10), None).await;

    let schema = build_test_schema(db);
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
    let db = fresh_browse_db().await;
    for i in 0..5 {
        seed_movie(&db, &format!("M{i}"), now_minus_days(i + 1), None).await;
    }

    let schema = build_test_schema(db);
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
    let db = fresh_browse_db().await;
    seed_movie(&db, "Movie 1", now_minus_days(1), None).await;
    seed_tv_show(&db, "Show 1", now_minus_days(1)).await;

    let schema = build_test_schema(db);
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
    let db = fresh_browse_db().await;
    seed_movie(&db, "M", now_minus_days(1), None).await;
    seed_tv_show(&db, "S", now_minus_days(2)).await;

    let schema = build_test_schema(db);
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
    let db = fresh_browse_db().await;
    seed_movie(
        &db,
        "With Art",
        now_minus_days(1),
        Some(json!({"poster_path": "/abc.jpg", "backdrop_path": "/xyz.jpg"})),
    )
    .await;

    let schema = build_test_schema(db);
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
    let db = fresh_browse_db().await;
    let schema = build_test_schema(db);
    let resp = schema
        .execute(r"{ continueWatching(first: 10) { id } }")
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert!(data["continueWatching"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn anonymous_up_next_returns_empty_list() {
    let db = fresh_browse_db().await;
    let schema = build_test_schema(db);
    let resp = schema
        .execute(r"{ upNext(first: 10) { progressState } }")
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert!(data["upNext"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn anonymous_favorites_returns_empty_list() {
    let db = fresh_browse_db().await;
    let schema = build_test_schema(db);
    let resp = schema.execute(r"{ favorites(first: 10) { id } }").await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert!(data["favorites"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn anonymous_unwatched_returns_empty_list() {
    let db = fresh_browse_db().await;
    let schema = build_test_schema(db);
    let resp = schema.execute(r"{ unwatched(first: 10) { id } }").await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert!(data["unwatched"].as_array().unwrap().is_empty());
}
