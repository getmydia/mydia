//! U10.c integration tests — derived media field resolvers.
//!
//! Covers the `#[ComplexObject]` impls on Movie / `TvShow` / Episode
//! that pull derived fields out of the metadata JSON blob, prefix
//! image URLs with the TMDB CDN, and run extra DB queries for
//! `files`, `seasons`, `show`, and `hasFile`.

mod common;

use chrono::{TimeZone, Utc};
use mydia_rs_db::insert_active_model;
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_entities::{episodes, media_files, media_items};
use sea_orm::{DatabaseConnection, Set};
use serde_json::json;

use common::{build_test_schema, fresh_browse_db};

fn sample_dt() -> DateTimeSecs {
    DateTimeSecs::from(Utc.with_ymd_and_hms(2024, 1, 1, 0, 0, 0).unwrap())
}

async fn seed_movie_with_metadata(
    db: &DatabaseConnection,
    title: &str,
    metadata: serde_json::Value,
    category: Option<&str>,
) -> UuidText {
    let id = UuidText::new_v4();
    let now = sample_dt();
    let metadata_text = serde_json::to_string(&metadata).unwrap();
    let am = media_items::ActiveModel {
        id: Set(id),
        r#type: Set("movie".to_owned()),
        title: Set(title.to_owned()),
        original_title: Set(None),
        year: Set(Some(2020)),
        tmdb_id: Set(Some(1)),
        imdb_id: Set(None),
        metadata: Set(Some(metadata_text)),
        monitored: Set(Some(true)),
        inserted_at: Set(now),
        updated_at: Set(now),
        quality_profile_id: Set(None),
        category: Set(category.map(std::borrow::ToOwned::to_owned)),
        category_override: Set(false),
        monitoring_preset: Set(Some("all".to_owned())),
        seasons_refreshed_at: Set(None),
        tvdb_id: Set(None),
    };
    insert_active_model(am, db).await.unwrap();

    let file_am = media_files::ActiveModel {
        id: Set(UuidText::new_v4()),
        media_item_id: Set(Some(id)),
        episode_id: Set(None),
        path: Set(None),
        size: Set(None),
        quality_profile_id: Set(None),
        resolution: Set(Some("1080p".to_owned())),
        codec: Set(Some("h264".to_owned())),
        hdr_format: Set(None),
        audio_codec: Set(None),
        bitrate: Set(None),
        verified_at: Set(None),
        metadata: Set(None),
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
    insert_active_model(file_am, db).await.unwrap();
    id
}

async fn seed_tv_show_with_metadata(
    db: &DatabaseConnection,
    title: &str,
    metadata: serde_json::Value,
    category: Option<&str>,
) -> UuidText {
    let id = UuidText::new_v4();
    let now = sample_dt();
    let metadata_text = serde_json::to_string(&metadata).unwrap();
    let am = media_items::ActiveModel {
        id: Set(id),
        r#type: Set("tv_show".to_owned()),
        title: Set(title.to_owned()),
        original_title: Set(None),
        year: Set(Some(2020)),
        tmdb_id: Set(Some(2)),
        imdb_id: Set(None),
        metadata: Set(Some(metadata_text)),
        monitored: Set(Some(true)),
        inserted_at: Set(now),
        updated_at: Set(now),
        quality_profile_id: Set(None),
        category: Set(category.map(std::borrow::ToOwned::to_owned)),
        category_override: Set(false),
        monitoring_preset: Set(Some("all".to_owned())),
        seasons_refreshed_at: Set(None),
        tvdb_id: Set(None),
    };
    insert_active_model(am, db).await.unwrap();

    // Seed a file so has_files matches.
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
    insert_active_model(file_am, db).await.unwrap();
    id
}

async fn seed_episode(
    db: &DatabaseConnection,
    media_item_id: UuidText,
    season: i32,
    episode: i32,
    title: &str,
    metadata: Option<serde_json::Value>,
) -> UuidText {
    let id = UuidText::new_v4();
    let now = sample_dt();
    let metadata_text = metadata.map(|m| serde_json::to_string(&m).unwrap());
    let am = episodes::ActiveModel {
        id: Set(id),
        media_item_id: Set(media_item_id),
        season_number: Set(season),
        episode_number: Set(episode),
        title: Set(Some(title.to_owned())),
        air_date: Set(None),
        metadata: Set(metadata_text),
        monitored: Set(Some(true)),
        inserted_at: Set(now),
        updated_at: Set(now),
    };
    insert_active_model(am, db).await.unwrap();
    id
}

async fn seed_episode_file(
    db: &DatabaseConnection,
    media_item_id: UuidText,
    episode_id: UuidText,
    codec: &str,
) {
    let now = sample_dt();
    let am = media_files::ActiveModel {
        id: Set(UuidText::new_v4()),
        media_item_id: Set(Some(media_item_id)),
        episode_id: Set(Some(episode_id)),
        path: Set(None),
        size: Set(None),
        quality_profile_id: Set(None),
        resolution: Set(None),
        codec: Set(Some(codec.to_owned())),
        hdr_format: Set(None),
        audio_codec: Set(None),
        bitrate: Set(None),
        verified_at: Set(None),
        metadata: Set(None),
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
    insert_active_model(am, db).await.unwrap();
}

#[tokio::test]
async fn movie_derived_fields_resolve_from_metadata() {
    let db = fresh_browse_db().await;
    seed_movie_with_metadata(
        &db,
        "Inception",
        json!({
            "overview": "A thief who steals corporate secrets...",
            "runtime": 148,
            "genres": ["Action", "Science Fiction"],
            "vote_average": 8.4,
            "poster_path": "/posters/inception.jpg",
            "backdrop_path": "/backdrops/inception.jpg"
        }),
        Some("standard"),
    )
    .await;

    let schema = build_test_schema(db);
    let resp = schema
        .execute(
            r"{
                movies(first: 10) {
                    edges {
                        node {
                            title overview runtime genres rating contentRating
                            category
                            artwork { posterUrl backdropUrl thumbnailUrl }
                        }
                    }
                }
            }",
        )
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let node = &data["movies"]["edges"][0]["node"];
    assert_eq!(node["title"], "Inception");
    assert_eq!(node["overview"], "A thief who steals corporate secrets...");
    assert_eq!(node["runtime"], 148);
    assert_eq!(node["genres"], json!(["Action", "Science Fiction"]));
    assert_eq!(node["rating"], 8.4);
    assert_eq!(node["contentRating"], serde_json::Value::Null);
    assert_eq!(node["category"], "STANDARD");
    // ImageUrl prefixes TMDB CDN + sized path.
    assert_eq!(
        node["artwork"]["posterUrl"],
        "https://image.tmdb.org/t/p/w500/posters/inception.jpg"
    );
    assert_eq!(
        node["artwork"]["backdropUrl"],
        "https://image.tmdb.org/t/p/original/backdrops/inception.jpg"
    );
    assert!(node["artwork"]["thumbnailUrl"].is_null());
}

#[tokio::test]
async fn movie_artwork_returns_null_when_paths_absent() {
    let db = fresh_browse_db().await;
    seed_movie_with_metadata(&db, "No Art", json!({"overview": "..."}), None).await;

    let schema = build_test_schema(db);
    let resp = schema
        .execute(r"{ movies(first: 10) { edges { node { artwork { posterUrl } } } } }")
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert!(data["movies"]["edges"][0]["node"]["artwork"].is_null());
}

#[tokio::test]
async fn movie_files_returns_seeded_media_file() {
    let db = fresh_browse_db().await;
    seed_movie_with_metadata(&db, "A", json!({}), None).await;

    let schema = build_test_schema(db);
    let resp = schema
        .execute(
            r"{
                movies(first: 10) {
                    edges {
                        node {
                            files { id codec resolution streamUrl directPlayUrl directPlaySupported }
                        }
                    }
                }
            }",
        )
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let files = data["movies"]["edges"][0]["node"]["files"]
        .as_array()
        .unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0]["codec"], "h264");
    assert_eq!(files[0]["resolution"], "1080p");
    assert_eq!(files[0]["directPlaySupported"], true);
    let stream_url = files[0]["streamUrl"].as_str().unwrap();
    assert!(stream_url.starts_with("/api/v1/stream/file/"));
    let direct_url = files[0]["directPlayUrl"].as_str().unwrap();
    assert!(direct_url.ends_with("?strategy=DIRECT_PLAY"));
}

#[tokio::test]
async fn movie_progress_and_is_favorite_anonymous_fallback() {
    let db = fresh_browse_db().await;
    seed_movie_with_metadata(&db, "A", json!({}), None).await;

    let schema = build_test_schema(db);
    let resp = schema
        .execute(
            r"{ movies(first: 10) { edges { node { progress { positionSeconds } isFavorite } } } }",
        )
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let node = &data["movies"]["edges"][0]["node"];
    assert!(node["progress"].is_null());
    assert_eq!(node["isFavorite"], false);
}

#[tokio::test]
async fn tv_show_derived_fields_resolve_from_metadata() {
    let db = fresh_browse_db().await;
    seed_tv_show_with_metadata(
        &db,
        "A Show",
        json!({
            "overview": "Big tent show",
            "status": "Continuing",
            "genres": ["Drama"],
            "vote_average": 7.7,
            "poster_path": "/show.jpg"
        }),
        Some("anime"),
    )
    .await;

    let schema = build_test_schema(db);
    let resp = schema
        .execute(
            r"{ tvShows(first: 10) { edges { node {
                title status overview rating category genres
                artwork { posterUrl }
            } } } }",
        )
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let node = &data["tvShows"]["edges"][0]["node"];
    assert_eq!(node["status"], "Continuing");
    assert_eq!(node["overview"], "Big tent show");
    assert_eq!(node["rating"], 7.7);
    assert_eq!(node["category"], "ANIME");
    assert_eq!(node["genres"], json!(["Drama"]));
    assert_eq!(
        node["artwork"]["posterUrl"],
        "https://image.tmdb.org/t/p/w500/show.jpg"
    );
}

#[tokio::test]
async fn tv_show_aggregates_seasons_and_counts() {
    let db = fresh_browse_db().await;
    let show_id = seed_tv_show_with_metadata(&db, "S", json!({}), None).await;
    // 2 seasons, 3 episodes total.
    for &(season, episode) in &[(1, 1), (1, 2), (2, 1)] {
        seed_episode(&db, show_id, season, episode, "X", None).await;
    }

    let schema = build_test_schema(db);
    let resp = schema
        .execute(
            r"{ tvShows(first: 10) { edges { node {
                seasonCount episodeCount
                seasons { seasonNumber episodeCount }
                nextEpisode { id }
            } } } }",
        )
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let node = &data["tvShows"]["edges"][0]["node"];
    assert_eq!(node["seasonCount"], 2);
    assert_eq!(node["episodeCount"], 3);
    let seasons = node["seasons"].as_array().unwrap();
    assert_eq!(seasons.len(), 2);
    assert_eq!(seasons[0]["seasonNumber"], 1);
    assert_eq!(seasons[0]["episodeCount"], 2);
    assert_eq!(seasons[1]["seasonNumber"], 2);
    assert_eq!(seasons[1]["episodeCount"], 1);
    // Anonymous: no next episode.
    assert!(node["nextEpisode"].is_null());
}

#[tokio::test]
async fn episode_derived_fields_and_show_resolver() {
    let db = fresh_browse_db().await;
    let show_id = seed_tv_show_with_metadata(&db, "Show", json!({}), None).await;
    let ep_id = seed_episode(
        &db,
        show_id,
        1,
        1,
        "Pilot",
        Some(json!({
            "overview": "Episode synopsis",
            "runtime": 42,
            "still_path": "/still.jpg"
        })),
    )
    .await;
    seed_episode_file(&db, show_id, ep_id, "hevc").await;

    let schema = build_test_schema(db);
    let ep_global_id = format!("episode:{}", ep_id.0);
    let query = format!(
        r#"{{
            episode(id: "{ep_global_id}") {{
                title overview runtime thumbnailUrl hasFile
                files {{ codec }}
                show {{ title }}
            }}
        }}"#
    );
    let resp = schema.execute(&*query).await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let ep = &data["episode"];
    assert_eq!(ep["title"], "Pilot");
    assert_eq!(ep["overview"], "Episode synopsis");
    assert_eq!(ep["runtime"], 42);
    assert_eq!(
        ep["thumbnailUrl"],
        "https://image.tmdb.org/t/p/w300/still.jpg"
    );
    assert_eq!(ep["hasFile"], true);
    assert_eq!(ep["files"][0]["codec"], "hevc");
    assert_eq!(ep["show"]["title"], "Show");
}
