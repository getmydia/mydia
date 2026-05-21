//! U11 integration tests — search, streaming, and playback resolvers.
//!
//! Each test builds an in-process `SQLite` DB matching the relevant
//! Phoenix tables, seeds rows, and executes operations through the
//! merged schema. Auth context is attached when the resolver requires
//! it; the schema's own auth gating is exercised via the unauthenticated
//! cases.

use std::time::Duration;

use async_graphql::{Request, Variables};
use chrono::{TimeZone, Utc};
use mydia_rs_auth::role::Role;
use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};
use mydia_rs_db::{
    connect_from_config,
    types::{DateTimeSecs, JsonMap, UuidText},
    Db,
};
use mydia_rs_graphql::context::{CurrentUser, GraphqlRequestContext};
use mydia_rs_graphql::{build_schema, GraphqlAppState, MydiaSchema};
use mydia_rs_pubsub::{recv_with_timeout, Pubsub};
use serde_json::json;
use tempfile::TempDir;
use uuid::Uuid;

const SCHEMA_SQL: &str = include_str!("fixtures/u11_schema.sql");

async fn fresh_schema() -> (Db, TempDir) {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("u11.db");
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

fn sample_dt(year: i32, month: u32, day: u32) -> DateTimeSecs {
    DateTimeSecs::from(Utc.with_ymd_and_hms(year, month, day, 0, 0, 0).unwrap())
}

async fn seed_user(db: &Db, id: UuidText, username: &str) {
    let pool = db.as_sqlite().unwrap();
    let now = sample_dt(2024, 1, 1);
    sqlx::query(
        "INSERT INTO users (id, username, role, inserted_at, updated_at)
         VALUES (?, ?, 'user', ?, ?)",
    )
    .bind(id)
    .bind(username)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .expect("seed user");
}

async fn seed_movie(db: &Db, id: UuidText, title: &str, metadata: serde_json::Value) {
    let pool = db.as_sqlite().unwrap();
    let now = sample_dt(2024, 1, 1);
    sqlx::query(
        "INSERT INTO media_items (id, type, title, year, tmdb_id, metadata,
            monitored, monitoring_preset, category_override, inserted_at, updated_at)
         VALUES (?, 'movie', ?, 2024, 42, ?, 1, 'all', 0, ?, ?)",
    )
    .bind(id)
    .bind(title)
    .bind(JsonMap(metadata))
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .expect("seed movie");
}

async fn seed_tv_show(db: &Db, id: UuidText, title: &str) {
    let pool = db.as_sqlite().unwrap();
    let now = sample_dt(2024, 1, 1);
    sqlx::query(
        "INSERT INTO media_items (id, type, title, year, tmdb_id, metadata,
            monitored, monitoring_preset, category_override, inserted_at, updated_at)
         VALUES (?, 'tv_show', ?, 2020, 99, ?, 1, 'all', 0, ?, ?)",
    )
    .bind(id)
    .bind(title)
    .bind(JsonMap(json!({})))
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .expect("seed tv_show");
}

async fn seed_episode(
    db: &Db,
    id: UuidText,
    show_id: UuidText,
    season: i32,
    episode: i32,
    title: &str,
) {
    let pool = db.as_sqlite().unwrap();
    let now = sample_dt(2024, 1, 1);
    sqlx::query(
        "INSERT INTO episodes (id, media_item_id, season_number, episode_number, title,
            monitored, inserted_at, updated_at)
         VALUES (?, ?, ?, ?, ?, 1, ?, ?)",
    )
    .bind(id)
    .bind(show_id)
    .bind(season)
    .bind(episode)
    .bind(title)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .expect("seed episode");
}

async fn seed_media_file_with_metadata(
    db: &Db,
    id: UuidText,
    media_item_id: Option<UuidText>,
    episode_id: Option<UuidText>,
    duration_seconds: f64,
) {
    let pool = db.as_sqlite().unwrap();
    let now = sample_dt(2024, 1, 1);
    let metadata = JsonMap(json!({
        "duration": duration_seconds,
        "width": 1920,
        "height": 1080,
        "container": "matroska,webm"
    }));
    sqlx::query(
        "INSERT INTO media_files (id, media_item_id, episode_id, codec, audio_codec, resolution,
            bitrate, analysis_attempts, metadata, inserted_at, updated_at)
         VALUES (?, ?, ?, 'h264', 'aac', '1080p', 5000000, 0, ?, ?, ?)",
    )
    .bind(id)
    .bind(media_item_id)
    .bind(episode_id)
    .bind(metadata)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await
    .expect("seed media file");
}

fn current_user(id: Uuid, username: &str) -> CurrentUser {
    CurrentUser {
        id,
        username: username.to_owned(),
        role: Role::User,
    }
}

async fn execute_authed(
    schema: &MydiaSchema,
    user: &CurrentUser,
    query: &str,
    variables: Variables,
) -> async_graphql::Response {
    let request = Request::new(query)
        .variables(variables)
        .data(GraphqlRequestContext::with_user(user.clone()));
    schema.execute(request).await
}

async fn execute_anon(
    schema: &MydiaSchema,
    query: &str,
    variables: Variables,
) -> async_graphql::Response {
    let request = Request::new(query)
        .variables(variables)
        .data(GraphqlRequestContext::anonymous());
    schema.execute(request).await
}

// ──────────── Search ─────────────────────────────────────────────

#[tokio::test]
async fn search_with_substring_matches_case_insensitive() {
    let (db, _tmp) = fresh_schema().await;
    seed_movie(
        &db,
        UuidText::new_v4(),
        "Dune",
        json!({"poster_path": "/p.jpg"}),
    )
    .await;
    seed_movie(&db, UuidText::new_v4(), "Arrival", json!({})).await;
    seed_movie(&db, UuidText::new_v4(), "DUNE Part Two", json!({})).await;

    let schema = build_schema(GraphqlAppState::new(db));
    let response = schema
        .execute(r#"{ search(query: "dune") { totalCount results { title type id artwork { posterUrl } } } }"#)
        .await;
    assert!(response.errors.is_empty(), "errors: {:?}", response.errors);
    let data = response.data.into_json().unwrap();
    assert_eq!(data["search"]["totalCount"], 2);
    let titles: Vec<String> = data["search"]["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["title"].as_str().unwrap().to_owned())
        .collect();
    // ASC title order — "Dune" comes before "DUNE Part Two" (the COLLATE NOCASE keeps them sorted).
    assert!(titles.contains(&"Dune".to_owned()));
    assert!(titles.contains(&"DUNE Part Two".to_owned()));
    // First result with poster_path should expose artwork.
    let dune = data["search"]["results"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["title"] == "Dune")
        .unwrap();
    assert_eq!(dune["artwork"]["posterUrl"], "/p.jpg");
    assert!(dune["id"].as_str().unwrap().starts_with("movie:"));
}

#[tokio::test]
async fn search_empty_query_returns_empty_results() {
    let (db, _tmp) = fresh_schema().await;
    let schema = build_schema(GraphqlAppState::new(db));
    let response = schema
        .execute(r#"{ search(query: "") { totalCount results { title } } }"#)
        .await;
    assert!(response.errors.is_empty(), "errors: {:?}", response.errors);
    let data = response.data.into_json().unwrap();
    assert_eq!(data["search"]["totalCount"], 0);
    assert_eq!(data["search"]["results"].as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn search_with_types_filter_narrows_to_kind() {
    let (db, _tmp) = fresh_schema().await;
    seed_movie(&db, UuidText::new_v4(), "Foo Movie", json!({})).await;
    seed_tv_show(&db, UuidText::new_v4(), "Foo Show").await;

    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(
            r#"{ search(query: "foo", types: [MOVIE]) { totalCount results { title type } } }"#,
        )
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["search"]["totalCount"], 1);
    assert_eq!(data["search"]["results"][0]["title"], "Foo Movie");
    assert_eq!(data["search"]["results"][0]["type"], "MOVIE");
}

#[tokio::test]
async fn search_respects_first_limit() {
    let (db, _tmp) = fresh_schema().await;
    for i in 0..5 {
        seed_movie(&db, UuidText::new_v4(), &format!("Match {i}"), json!({})).await;
    }
    let schema = build_schema(GraphqlAppState::new(db));
    let resp = schema
        .execute(r#"{ search(query: "match", first: 2) { totalCount results { title } } }"#)
        .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["search"]["totalCount"], 2);
    assert_eq!(data["search"]["results"].as_array().unwrap().len(), 2);
}

// ──────────── Streaming candidates ───────────────────────────────

#[tokio::test]
async fn streaming_candidates_requires_authentication() {
    let (db, _tmp) = fresh_schema().await;
    let file_id = UuidText::new_v4();
    let movie_id = UuidText::new_v4();
    seed_movie(&db, movie_id, "M", json!({})).await;
    seed_media_file_with_metadata(&db, file_id, Some(movie_id), None, 7200.0).await;

    let schema = build_schema(GraphqlAppState::new(db));
    let resp = execute_anon(
        &schema,
        r#"query S($id: ID!) {
            streamingCandidates(contentType: "file", id: $id) {
                fileId
                candidates { strategy mime container videoCodec audioCodec }
            }
        }"#,
        Variables::from_json(json!({"id": file_id.0.to_string()})),
    )
    .await;
    assert!(!resp.errors.is_empty(), "expected auth error");
    assert!(resp.errors[0].message.contains("Authentication required"));
}

#[tokio::test]
async fn streaming_candidates_returns_metadata_from_file() {
    let (db, _tmp) = fresh_schema().await;
    let user_id = Uuid::new_v4();
    seed_user(&db, UuidText::from(user_id), "alice").await;
    let movie_id = UuidText::new_v4();
    let file_id = UuidText::new_v4();
    seed_movie(&db, movie_id, "M", json!({})).await;
    seed_media_file_with_metadata(&db, file_id, Some(movie_id), None, 7200.0).await;

    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(user_id, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r#"query S($id: ID!) {
            streamingCandidates(contentType: "file", id: $id) {
                fileId
                candidates { strategy mime container videoCodec audioCodec }
                metadata { duration width height resolution originalCodec originalAudioCodec container }
            }
        }"#,
        Variables::from_json(json!({"id": file_id.0.to_string()})),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["streamingCandidates"]["fileId"], file_id.0.to_string());
    assert_eq!(data["streamingCandidates"]["metadata"]["duration"], 7200.0);
    assert_eq!(data["streamingCandidates"]["metadata"]["width"], 1920);
    assert_eq!(data["streamingCandidates"]["metadata"]["height"], 1080);
    assert_eq!(
        data["streamingCandidates"]["metadata"]["originalCodec"],
        "h264"
    );
    assert_eq!(
        data["streamingCandidates"]["metadata"]["originalAudioCodec"],
        "aac"
    );
    let candidates = data["streamingCandidates"]["candidates"]
        .as_array()
        .unwrap();
    assert!(!candidates.is_empty());
    assert_eq!(candidates[0]["strategy"], "TRANSCODE");
    assert_eq!(candidates[0]["mime"], "application/vnd.apple.mpegurl");
}

#[tokio::test]
async fn streaming_candidates_resolves_by_movie_id() {
    let (db, _tmp) = fresh_schema().await;
    let user_id = Uuid::new_v4();
    seed_user(&db, UuidText::from(user_id), "bob").await;
    let movie_id = UuidText::new_v4();
    seed_movie(&db, movie_id, "M", json!({})).await;
    seed_media_file_with_metadata(&db, UuidText::new_v4(), Some(movie_id), None, 3600.0).await;

    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(user_id, "bob");
    let resp = execute_authed(
        &schema,
        &user,
        r#"query S($id: ID!) {
            streamingCandidates(contentType: "movie", id: $id) { metadata { duration } }
        }"#,
        Variables::from_json(json!({"id": movie_id.0.to_string()})),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["streamingCandidates"]["metadata"]["duration"], 3600.0);
}

#[tokio::test]
async fn streaming_candidates_unknown_content_type_errors() {
    let (db, _tmp) = fresh_schema().await;
    let user_id = Uuid::new_v4();
    seed_user(&db, UuidText::from(user_id), "carol").await;

    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(user_id, "carol");
    let resp = execute_authed(
        &schema,
        &user,
        r#"query S { streamingCandidates(contentType: "garbage", id: "abc") { fileId } }"#,
        Variables::default(),
    )
    .await;
    assert!(!resp.errors.is_empty(), "expected error");
    assert!(resp.errors[0].message.contains("Invalid content type"));
}

// ──────────── start / end streaming session ──────────────────────

#[tokio::test]
async fn start_streaming_session_returns_session_id_and_duration() {
    let (db, _tmp) = fresh_schema().await;
    let user_id = Uuid::new_v4();
    seed_user(&db, UuidText::from(user_id), "alice").await;
    let movie_id = UuidText::new_v4();
    let file_id = UuidText::new_v4();
    seed_movie(&db, movie_id, "M", json!({})).await;
    seed_media_file_with_metadata(&db, file_id, Some(movie_id), None, 1234.5).await;

    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(user_id, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r"mutation S($id: ID!) {
            startStreamingSession(fileId: $id, strategy: TRANSCODE) {
                sessionId duration
            }
        }",
        Variables::from_json(json!({"id": file_id.0.to_string()})),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    let session_id = data["startStreamingSession"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(!session_id.is_empty());
    // U11 returns a UUID-shaped session id (36 chars including hyphens).
    assert_eq!(session_id.len(), 36);
    assert_eq!(data["startStreamingSession"]["duration"], 1234.5);
}

#[tokio::test]
async fn start_streaming_session_requires_auth() {
    let (db, _tmp) = fresh_schema().await;
    let schema = build_schema(GraphqlAppState::new(db));
    let resp = execute_anon(
        &schema,
        r#"mutation { startStreamingSession(fileId: "anything", strategy: TRANSCODE) { sessionId duration } }"#,
        Variables::default(),
    )
    .await;
    assert!(!resp.errors.is_empty());
    assert!(resp.errors[0].message.contains("Authentication required"));
}

#[tokio::test]
async fn start_streaming_session_file_not_found_errors() {
    let (db, _tmp) = fresh_schema().await;
    let user_id = Uuid::new_v4();
    seed_user(&db, UuidText::from(user_id), "alice").await;
    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(user_id, "alice");
    let missing_id = Uuid::new_v4().to_string();
    let resp = execute_authed(
        &schema,
        &user,
        r"mutation S($id: ID!) { startStreamingSession(fileId: $id, strategy: HLS_COPY) { sessionId } }",
        Variables::from_json(json!({"id": missing_id})),
    )
    .await;
    assert!(!resp.errors.is_empty());
    assert!(resp.errors[0].message.contains("Media file not found"));
}

#[tokio::test]
async fn end_streaming_session_returns_true_even_for_unknown() {
    let (db, _tmp) = fresh_schema().await;
    let user_id = Uuid::new_v4();
    seed_user(&db, UuidText::from(user_id), "alice").await;
    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(user_id, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r#"mutation { endStreamingSession(sessionId: "ghost") }"#,
        Variables::default(),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["endStreamingSession"], true);
}

// ──────────── update*Progress + broadcast ────────────────────────

#[tokio::test]
async fn update_movie_progress_writes_and_broadcasts_on_node_id_topic() {
    let (db, _tmp) = fresh_schema().await;
    let user_id = Uuid::new_v4();
    seed_user(&db, UuidText::from(user_id), "alice").await;
    let movie_id = UuidText::new_v4();
    seed_movie(&db, movie_id, "M", json!({})).await;

    let pubsub = Pubsub::new();
    let movie_node_id = format!("movie:{}", movie_id.0);
    let mut rx = pubsub.subscribe(&movie_node_id);

    let state = GraphqlAppState::with_pubsub(db.clone(), pubsub);
    let schema = build_schema(state);
    let user = current_user(user_id, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r"mutation M($id: ID!) {
            updateMovieProgress(movieId: $id, positionSeconds: 60, durationSeconds: 600) {
                positionSeconds durationSeconds percentage watched
            }
        }",
        Variables::from_json(json!({"id": movie_id.0.to_string()})),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["updateMovieProgress"]["positionSeconds"], 60);
    assert_eq!(data["updateMovieProgress"]["durationSeconds"], 600);
    assert!((data["updateMovieProgress"]["percentage"].as_f64().unwrap() - 10.0).abs() < 1e-9);
    assert_eq!(data["updateMovieProgress"]["watched"], false);

    // Confirm the broadcast arrived on the encoded-node-id topic.
    let event = recv_with_timeout(&mut rx, Duration::from_secs(1))
        .await
        .expect("recv timed out")
        .expect("event");
    assert_eq!(event.payload["position_seconds"], 60);
    assert_eq!(event.payload["duration_seconds"], 600);
}

#[tokio::test]
async fn update_movie_progress_at_90_percent_auto_marks_watched() {
    let (db, _tmp) = fresh_schema().await;
    let user_id = Uuid::new_v4();
    seed_user(&db, UuidText::from(user_id), "alice").await;
    let movie_id = UuidText::new_v4();
    seed_movie(&db, movie_id, "M", json!({})).await;
    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(user_id, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r"mutation M($id: ID!) {
            updateMovieProgress(movieId: $id, positionSeconds: 540, durationSeconds: 600) {
                watched percentage
            }
        }",
        Variables::from_json(json!({"id": movie_id.0.to_string()})),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["updateMovieProgress"]["watched"], true);
    assert!((data["updateMovieProgress"]["percentage"].as_f64().unwrap() - 90.0).abs() < 1e-9);
}

#[tokio::test]
async fn update_movie_progress_negative_position_rejects() {
    let (db, _tmp) = fresh_schema().await;
    let user_id = Uuid::new_v4();
    seed_user(&db, UuidText::from(user_id), "alice").await;
    let movie_id = UuidText::new_v4();
    seed_movie(&db, movie_id, "M", json!({})).await;
    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(user_id, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r"mutation M($id: ID!) {
            updateMovieProgress(movieId: $id, positionSeconds: -1, durationSeconds: 600) { positionSeconds }
        }",
        Variables::from_json(json!({"id": movie_id.0.to_string()})),
    )
    .await;
    assert!(!resp.errors.is_empty(), "expected validation error");
    assert!(resp.errors[0].message.contains("position_seconds"));
}

#[tokio::test]
async fn update_episode_progress_writes_and_broadcasts_on_episode_topic() {
    let (db, _tmp) = fresh_schema().await;
    let user_id = Uuid::new_v4();
    seed_user(&db, UuidText::from(user_id), "alice").await;
    let show_id = UuidText::new_v4();
    seed_tv_show(&db, show_id, "Show").await;
    let ep_id = UuidText::new_v4();
    seed_episode(&db, ep_id, show_id, 1, 1, "S1E1").await;

    let pubsub = Pubsub::new();
    let ep_node_id = format!("episode:{}", ep_id.0);
    let mut rx = pubsub.subscribe(&ep_node_id);

    let state = GraphqlAppState::with_pubsub(db.clone(), pubsub);
    let schema = build_schema(state);
    let user = current_user(user_id, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r"mutation M($id: ID!) {
            updateEpisodeProgress(episodeId: $id, positionSeconds: 120, durationSeconds: 1200) {
                positionSeconds percentage watched
            }
        }",
        Variables::from_json(json!({"id": ep_id.0.to_string()})),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["updateEpisodeProgress"]["positionSeconds"], 120);
    let event = recv_with_timeout(&mut rx, Duration::from_secs(1))
        .await
        .expect("recv timed out")
        .expect("event");
    assert_eq!(event.payload["position_seconds"], 120);
}

// ──────────── mark watched / unwatched ───────────────────────────

#[tokio::test]
async fn mark_movie_watched_creates_progress_when_none_exists() {
    let (db, _tmp) = fresh_schema().await;
    let user_id = Uuid::new_v4();
    seed_user(&db, UuidText::from(user_id), "alice").await;
    let movie_id = UuidText::new_v4();
    seed_movie(&db, movie_id, "M", json!({})).await;
    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(user_id, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r"mutation M($id: ID!) { markMovieWatched(movieId: $id) { title } }",
        Variables::from_json(json!({"id": movie_id.0.to_string()})),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["markMovieWatched"]["title"], "M");
}

#[tokio::test]
async fn mark_movie_unwatched_deletes_progress() {
    let (db, _tmp) = fresh_schema().await;
    let user_id = Uuid::new_v4();
    seed_user(&db, UuidText::from(user_id), "alice").await;
    let movie_id = UuidText::new_v4();
    seed_movie(&db, movie_id, "M", json!({})).await;
    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(user_id, "alice");
    // First mark watched, then unwatched.
    let _ = execute_authed(
        &schema,
        &user,
        r"mutation M($id: ID!) { markMovieWatched(movieId: $id) { title } }",
        Variables::from_json(json!({"id": movie_id.0.to_string()})),
    )
    .await;
    let resp = execute_authed(
        &schema,
        &user,
        r"mutation M($id: ID!) { markMovieUnwatched(movieId: $id) { title } }",
        Variables::from_json(json!({"id": movie_id.0.to_string()})),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let data = resp.data.into_json().unwrap();
    assert_eq!(data["markMovieUnwatched"]["title"], "M");
}

#[tokio::test]
async fn mark_season_watched_creates_progress_for_every_episode() {
    let (db, _tmp) = fresh_schema().await;
    let user_id = Uuid::new_v4();
    seed_user(&db, UuidText::from(user_id), "alice").await;
    let show_id = UuidText::new_v4();
    seed_tv_show(&db, show_id, "Show").await;
    let ep1 = UuidText::new_v4();
    let ep2 = UuidText::new_v4();
    let other_season_ep = UuidText::new_v4();
    seed_episode(&db, ep1, show_id, 1, 1, "S1E1").await;
    seed_episode(&db, ep2, show_id, 1, 2, "S1E2").await;
    seed_episode(&db, other_season_ep, show_id, 2, 1, "S2E1").await;
    let schema = build_schema(GraphqlAppState::new(db.clone()));
    let user = current_user(user_id, "alice");
    let resp = execute_authed(
        &schema,
        &user,
        r"mutation M($id: ID!) { markSeasonWatched(showId: $id, seasonNumber: 1) { title } }",
        Variables::from_json(json!({"id": show_id.0.to_string()})),
    )
    .await;
    assert!(resp.errors.is_empty(), "errors: {:?}", resp.errors);
    let pool = db.as_sqlite().unwrap();
    let watched_episodes: Vec<String> = sqlx::query_scalar(
        "SELECT episode_id FROM playback_progress WHERE user_id = ? AND watched = 1",
    )
    .bind(UuidText::from(user_id))
    .fetch_all(pool)
    .await
    .unwrap();
    assert_eq!(watched_episodes.len(), 2);
    let ep1_str = ep1.0.to_string();
    let ep2_str = ep2.0.to_string();
    assert!(watched_episodes.contains(&ep1_str));
    assert!(watched_episodes.contains(&ep2_str));
    assert!(!watched_episodes.contains(&other_season_ep.0.to_string()));
}

// ──────────── toggle favorite ────────────────────────────────────

#[tokio::test]
async fn toggle_favorite_adds_then_removes() {
    let (db, _tmp) = fresh_schema().await;
    let user_id = Uuid::new_v4();
    seed_user(&db, UuidText::from(user_id), "alice").await;
    let movie_id = UuidText::new_v4();
    seed_movie(&db, movie_id, "M", json!({})).await;
    let schema = build_schema(GraphqlAppState::new(db));
    let user = current_user(user_id, "alice");
    let movie_str = movie_id.0.to_string();

    let resp1 = execute_authed(
        &schema,
        &user,
        r"mutation M($id: ID!) {
            toggleFavorite(mediaItemId: $id) { isFavorite mediaItemId }
        }",
        Variables::from_json(json!({"id": movie_str.clone()})),
    )
    .await;
    assert!(resp1.errors.is_empty(), "errors: {:?}", resp1.errors);
    let data1 = resp1.data.into_json().unwrap();
    assert_eq!(data1["toggleFavorite"]["isFavorite"], true);
    assert_eq!(data1["toggleFavorite"]["mediaItemId"], movie_str);

    let resp2 = execute_authed(
        &schema,
        &user,
        r"mutation M($id: ID!) {
            toggleFavorite(mediaItemId: $id) { isFavorite }
        }",
        Variables::from_json(json!({"id": movie_str.clone()})),
    )
    .await;
    assert!(resp2.errors.is_empty(), "errors: {:?}", resp2.errors);
    let data2 = resp2.data.into_json().unwrap();
    assert_eq!(data2["toggleFavorite"]["isFavorite"], false);
}

#[tokio::test]
async fn playback_mutations_require_authentication() {
    let (db, _tmp) = fresh_schema().await;
    let movie_id = UuidText::new_v4();
    seed_movie(&db, movie_id, "M", json!({})).await;
    let schema = build_schema(GraphqlAppState::new(db));
    let resp = execute_anon(
        &schema,
        r"mutation M($id: ID!) { updateMovieProgress(movieId: $id, positionSeconds: 1, durationSeconds: 100) { watched } }",
        Variables::from_json(json!({"id": movie_id.0.to_string()})),
    )
    .await;
    assert!(!resp.errors.is_empty());
    assert!(resp.errors[0].message.contains("Authentication required"));
}
