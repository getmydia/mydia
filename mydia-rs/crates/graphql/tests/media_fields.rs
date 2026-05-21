//! U10.c integration tests — derived media field resolvers.
//!
//! Covers the `#[ComplexObject]` impls on Movie / TvShow / Episode
//! that pull derived fields out of the metadata JSON blob, prefix
//! image URLs with the TMDB CDN, and run extra DB queries for
//! `files`, `seasons`, `show`, and `hasFile`.

use chrono::{TimeZone, Utc};
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
    let path = tmp.path().join("media_fields.db");
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

fn sample_dt() -> DateTimeSecs {
    DateTimeSecs::from(Utc.with_ymd_and_hms(2024, 1, 1, 0, 0, 0).unwrap())
}

async fn seed_movie_with_metadata(
    db: &Db,
    title: &str,
    metadata: serde_json::Value,
    category: Option<&str>,
) -> UuidText {
    let pool = db.as_sqlite().unwrap();
    let id = UuidText::new_v4();
    let now = sample_dt();
    let metadata_json = JsonMap(metadata);
    sqlx::query(
        "INSERT INTO media_items (id, type, title, year, tmdb_id, metadata,
            monitored, monitoring_preset, category, category_override, inserted_at, updated_at)
         VALUES (?, 'movie', ?, 2020, 1, ?, 1, 'all', ?, 0, ?, ?)",
    )
    .bind(id)
    .bind(title)
    .bind(metadata_json)
    .bind(category)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();
    let file_id = UuidText::new_v4();
    sqlx::query(
        "INSERT INTO media_files (id, media_item_id, codec, resolution, analysis_attempts,
            inserted_at, updated_at)
         VALUES (?, ?, 'h264', '1080p', 0, ?, ?)",
    )
    .bind(file_id)
    .bind(id)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();
    id
}

#[tokio::test]
async fn movie_derived_fields_resolve_from_metadata() {
    let (db, _tmp) = fresh_schema().await;
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

    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(
            r#"{
                movies(first: 10) {
                    edges {
                        node {
                            title overview runtime genres rating contentRating
                            category
                            artwork { posterUrl backdropUrl thumbnailUrl }
                        }
                    }
                }
            }"#,
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
    let (db, _tmp) = fresh_schema().await;
    seed_movie_with_metadata(&db, "No Art", json!({"overview": "..."}), None).await;

    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(r#"{ movies(first: 10) { edges { node { artwork { posterUrl } } } } }"#)
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert!(data["movies"]["edges"][0]["node"]["artwork"].is_null());
}

#[tokio::test]
async fn movie_files_returns_seeded_media_file() {
    let (db, _tmp) = fresh_schema().await;
    seed_movie_with_metadata(&db, "A", json!({}), None).await;

    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(
            r#"{
                movies(first: 10) {
                    edges {
                        node {
                            files { id codec resolution streamUrl directPlayUrl directPlaySupported }
                        }
                    }
                }
            }"#,
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
    let (db, _tmp) = fresh_schema().await;
    seed_movie_with_metadata(&db, "A", json!({}), None).await;

    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(
            r#"{ movies(first: 10) { edges { node { progress { positionSeconds } isFavorite } } } }"#,
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
    let (db, _tmp) = fresh_schema().await;
    let pool = db.as_sqlite().unwrap();
    let id = UuidText::new_v4();
    let now = sample_dt();
    let metadata = JsonMap(json!({
        "overview": "Big tent show",
        "status": "Continuing",
        "genres": ["Drama"],
        "vote_average": 7.7,
        "poster_path": "/show.jpg"
    }));
    sqlx::query(
        "INSERT INTO media_items (id, type, title, year, tmdb_id, metadata,
            monitored, monitoring_preset, category, category_override, inserted_at, updated_at)
         VALUES (?, 'tv_show', 'A Show', 2020, 2, ?, 1, 'all', 'anime', 0, ?, ?)",
    )
    .bind(id)
    .bind(metadata)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();
    // Seed a file so has_files matches.
    let file_id = UuidText::new_v4();
    sqlx::query(
        "INSERT INTO media_files (id, media_item_id, analysis_attempts, inserted_at, updated_at)
         VALUES (?, ?, 0, ?, ?)",
    )
    .bind(file_id)
    .bind(id)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();

    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(
            r#"{ tvShows(first: 10) { edges { node {
                title status overview rating category genres
                artwork { posterUrl }
            } } } }"#,
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
    let (db, _tmp) = fresh_schema().await;
    let pool = db.as_sqlite().unwrap();
    let show_id = UuidText::new_v4();
    let now = sample_dt();
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

    // 2 seasons, 3 episodes total.
    for &(season, episode) in &[(1, 1), (1, 2), (2, 1)] {
        let ep_id = UuidText::new_v4();
        sqlx::query(
            "INSERT INTO episodes (id, media_item_id, season_number, episode_number, title,
                monitored, inserted_at, updated_at)
             VALUES (?, ?, ?, ?, 'X', 1, ?, ?)",
        )
        .bind(ep_id)
        .bind(show_id)
        .bind(season)
        .bind(episode)
        .bind(now)
        .bind(now)
        .execute(pool)
        .await
        .unwrap();
    }

    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(
            r#"{ tvShows(first: 10) { edges { node {
                seasonCount episodeCount
                seasons { seasonNumber episodeCount }
                nextEpisode { id }
            } } } }"#,
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
    let (db, _tmp) = fresh_schema().await;
    let pool = db.as_sqlite().unwrap();
    let show_id = UuidText::new_v4();
    let now = sample_dt();
    sqlx::query(
        "INSERT INTO media_items (id, type, title, year, tmdb_id, metadata,
            monitored, monitoring_preset, category_override, inserted_at, updated_at)
         VALUES (?, 'tv_show', 'Show', 2020, 2, '{}', 1, 'all', 0, ?, ?)",
    )
    .bind(show_id)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();
    let ep_id = UuidText::new_v4();
    let ep_metadata = JsonMap(json!({
        "overview": "Episode synopsis",
        "runtime": 42,
        "still_path": "/still.jpg"
    }));
    sqlx::query(
        "INSERT INTO episodes (id, media_item_id, season_number, episode_number, title,
            metadata, monitored, inserted_at, updated_at)
         VALUES (?, ?, 1, 1, 'Pilot', ?, 1, ?, ?)",
    )
    .bind(ep_id)
    .bind(show_id)
    .bind(ep_metadata)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();
    // Seed an episode-scoped media file so hasFile is true.
    let file_id = UuidText::new_v4();
    sqlx::query(
        "INSERT INTO media_files (id, media_item_id, episode_id, codec, analysis_attempts,
            inserted_at, updated_at)
         VALUES (?, ?, ?, 'hevc', 0, ?, ?)",
    )
    .bind(file_id)
    .bind(show_id)
    .bind(ep_id)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .unwrap();

    let schema = build_schema(GraphqlAppState::new(db));
    let ep_global_id = format!("episode:{}", ep_id.0);
    let query = format!(
        r#"{{
            episode(id: "{}") {{
                title overview runtime thumbnailUrl hasFile
                files {{ codec }}
                show {{ title }}
            }}
        }}"#,
        ep_global_id
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
