//! Integration tests for the U33 REST API surface.
//!
//! Covers the load-bearing properties of the byte-range streaming
//! pipeline plus the scaffolded surface plus the per-route auth
//! pipeline attached in the U33 follow-up.
//!
//! - Full-body responses include `Accept-Ranges: bytes` + an
//!   `x-streaming-mode` header so the player can detect direct play.
//! - A valid `Range: bytes=START-END` header produces `206 Partial
//!   Content` with a correctly bounded body and a `Content-Range:
//!   bytes START-END/TOTAL` header.
//! - A `Range: bytes=START-` open-ended request returns the tail of
//!   the file.
//! - A malformed / out-of-bounds range returns `416 Range Not
//!   Satisfiable` with a `Content-Range: bytes */N` header.
//! - The router merges without panic and exposes the expected paths.
//! - Each route family rejects unauthenticated callers with 401.
//! - Each route family accepts a valid API key (or media token, for
//!   the streaming-tier endpoints) and falls through to the handler.
//! - Admin-only routes (`/api/v1/config`) reject non-admin callers
//!   with 403, even when the api-key auth is valid.

#![cfg(feature = "server")]

use std::io::Write;

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use chrono::Utc;
use http_body_util::BodyExt;
use mydia_rs_auth::api_key::hash_api_key;
use mydia_rs_auth::{MediaTokenCache, MediaTokenPermission, MediaTokenSigner};
use mydia_rs_db::Db;
use mydia_rs_jobs::storage::JobStorage;
use mydia_rs_pubsub::Pubsub;
use mydia_rs_web::api;
use mydia_rs_web::WebState;
use sqlx::sqlite::SqlitePoolOptions;
use tower::ServiceExt;

const SETUP_SQL: &str = "
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT,
    email TEXT,
    password_hash TEXT,
    role TEXT NOT NULL DEFAULT 'user',
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS api_keys (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    name TEXT,
    key_hash TEXT NOT NULL,
    key_prefix TEXT,
    permissions TEXT,
    last_used_at TEXT,
    expires_at TEXT,
    revoked_at TEXT,
    inserted_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS download_client_configs (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    priority INTEGER NOT NULL DEFAULT 1,
    host TEXT,
    port INTEGER,
    use_ssl INTEGER NOT NULL DEFAULT 0,
    url_base TEXT,
    username TEXT,
    password TEXT,
    api_key TEXT,
    category TEXT,
    download_directory TEXT,
    connection_settings TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS indexer_configs (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    priority INTEGER NOT NULL DEFAULT 1,
    base_url TEXT,
    api_key TEXT,
    indexer_ids TEXT,
    categories TEXT,
    rate_limit INTEGER,
    connection_settings TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS media_files (
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
);
";

/// Write `len` deterministic bytes (`i % 251`) to a tempfile so the
/// byte-range tests can assert exact body content. 251 is a prime
/// just under `u8::MAX` so the pattern doesn't accidentally repeat at
/// power-of-two offsets the player might happen to seek to.
fn write_fixture(len: usize) -> tempfile::NamedTempFile {
    let mut file = tempfile::Builder::new()
        .prefix("u33-stream-")
        .suffix(".mp4")
        .tempfile()
        .expect("create tempfile");
    let buf: Vec<u8> = (0..len).map(|i| (i % 251) as u8).collect();
    file.write_all(&buf).expect("write fixture");
    file.flush().expect("flush fixture");
    file
}

async fn collect(body: Body) -> Vec<u8> {
    body.collect()
        .await
        .expect("collect body")
        .to_bytes()
        .to_vec()
}

// ---------------------------------------------------------------------
// Byte-range / streaming pipeline — exercised via the test shim that
// skips the router (no auth, no DB).
// ---------------------------------------------------------------------

#[tokio::test]
async fn full_body_response_sets_accept_ranges_and_streaming_mode() {
    let fixture = write_fixture(2048);
    let headers = http::HeaderMap::new();
    let response = api::serve_file_for_tests(fixture.path(), &headers).await;

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get(header::ACCEPT_RANGES)
            .expect("accept-ranges header"),
        "bytes"
    );
    assert_eq!(
        response
            .headers()
            .get(header::CONTENT_LENGTH)
            .expect("content-length header"),
        "2048"
    );
    assert_eq!(
        response
            .headers()
            .get("x-streaming-mode")
            .expect("x-streaming-mode header"),
        "direct"
    );

    let body = collect(response.into_body()).await;
    assert_eq!(body.len(), 2048);
    assert_eq!(body[0], 0);
    assert_eq!(body[250], 250);
    assert_eq!(body[251], 0);
}

#[tokio::test]
async fn explicit_range_returns_206_with_bounded_body() {
    let fixture = write_fixture(4096);
    let mut headers = http::HeaderMap::new();
    headers.insert(header::RANGE, "bytes=100-199".parse().unwrap());

    let response = api::serve_file_for_tests(fixture.path(), &headers).await;

    assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(
        response
            .headers()
            .get(header::CONTENT_RANGE)
            .expect("content-range header"),
        "bytes 100-199/4096"
    );
    assert_eq!(
        response
            .headers()
            .get(header::CONTENT_LENGTH)
            .expect("content-length header"),
        "100"
    );

    let body = collect(response.into_body()).await;
    assert_eq!(body.len(), 100);
    assert_eq!(body[0], 100);
    assert_eq!(body[99], 199);
}

#[tokio::test]
async fn open_ended_range_returns_tail_of_file() {
    let fixture = write_fixture(1000);
    let mut headers = http::HeaderMap::new();
    headers.insert(header::RANGE, "bytes=500-".parse().unwrap());

    let response = api::serve_file_for_tests(fixture.path(), &headers).await;

    assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(
        response
            .headers()
            .get(header::CONTENT_RANGE)
            .expect("content-range header"),
        "bytes 500-999/1000"
    );

    let body = collect(response.into_body()).await;
    assert_eq!(body.len(), 500);
    assert_eq!(body[0], (500u32 % 251) as u8);
}

#[tokio::test]
async fn malformed_range_returns_416_with_content_range_star() {
    let fixture = write_fixture(1000);
    let mut headers = http::HeaderMap::new();
    headers.insert(header::RANGE, "bytes=invalid".parse().unwrap());

    let response = api::serve_file_for_tests(fixture.path(), &headers).await;

    assert_eq!(response.status(), StatusCode::RANGE_NOT_SATISFIABLE);
    assert_eq!(
        response
            .headers()
            .get(header::CONTENT_RANGE)
            .expect("content-range header"),
        "bytes */1000"
    );
}

#[tokio::test]
async fn out_of_bounds_range_returns_416() {
    let fixture = write_fixture(100);
    let mut headers = http::HeaderMap::new();
    headers.insert(header::RANGE, "bytes=200-300".parse().unwrap());

    let response = api::serve_file_for_tests(fixture.path(), &headers).await;

    assert_eq!(response.status(), StatusCode::RANGE_NOT_SATISFIABLE);
}

#[tokio::test]
async fn missing_file_returns_404() {
    let path = std::env::temp_dir().join("u33-missing-fixture-deadbeef.mp4");
    let headers = http::HeaderMap::new();
    let response = api::serve_file_for_tests(&path, &headers).await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

// ---------------------------------------------------------------------
// Auth pipeline — per Phoenix `router.ex:213-319`.
// ---------------------------------------------------------------------

struct AuthFixture {
    state: WebState,
    api_key: String,
    admin_api_key: String,
    media_signer: MediaTokenSigner,
    user_id: String,
}

async fn auth_fixture() -> AuthFixture {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("open in-memory sqlite");
    for stmt in SETUP_SQL.split(';') {
        let trimmed = stmt.trim();
        if !trimmed.is_empty() {
            sqlx::query(trimmed)
                .execute(&pool)
                .await
                .expect("apply schema");
        }
    }
    let db = Db::Sqlite(pool);

    let user_id = insert_user(&db, "user").await;
    let admin_id = insert_user(&db, "admin").await;

    let api_key = "mydia_test_user_key_aaaaaaaaaaaaaa".to_string();
    let admin_api_key = "mydia_test_admin_key_bbbbbbbbbbbbb".to_string();
    insert_api_key(&db, &user_id, &api_key).await;
    insert_api_key(&db, &admin_id, &admin_api_key).await;

    let secret = "test-guardian-secret-key-for-rest-tests";
    let media_signer = MediaTokenSigner::new(secret, 0);
    let media_cache = MediaTokenCache::new(std::time::Duration::from_secs(300));

    let pubsub = Pubsub::new();
    let storage: JobStorage<mydia_rs_jobs::workers::library_scanner::LibraryScannerArgs> =
        JobStorage::from_db(&db);

    // Anchor the streaming supervisor under a per-test tempdir so
    // parallel test runs don't collide on `/tmp/mydia-hls`. The
    // tempdir lives for the duration of the process — long enough
    // since each `auth_fixture` builds its own.
    let hls_temp = tempfile::Builder::new()
        .prefix("rest-api-hls-")
        .tempdir()
        .expect("hls temp dir");
    let supervisor_cfg = mydia_rs_streaming::SupervisorConfig {
        temp_base_dir: hls_temp.path().to_path_buf(),
        idle_check_interval: std::time::Duration::from_millis(50),
        idle_timeout: std::time::Duration::from_secs(60),
        ..Default::default()
    };
    let supervisor = mydia_rs_streaming::Supervisor::new(supervisor_cfg, pubsub.clone());

    let state = WebState::new(db, pubsub, storage, None)
        .with_media_signer(media_signer.clone(), media_cache)
        .with_streaming_supervisor(supervisor);
    // Leak the tempdir so it outlives the function (the supervisor
    // holds paths into it via the per-session temp dirs).
    std::mem::forget(hls_temp);

    AuthFixture {
        state,
        api_key,
        admin_api_key,
        media_signer,
        user_id,
    }
}

async fn insert_user(db: &Db, role: &str) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    if let Db::Sqlite(pool) = db {
        sqlx::query(
            "INSERT INTO users (id, username, email, role, inserted_at, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(&id)
        .bind(format!("user-{}", &id[..8]))
        .bind(format!("{}@example.com", &id[..8]))
        .bind(role)
        .bind(&now)
        .bind(&now)
        .execute(pool)
        .await
        .expect("insert user");
    }
    id
}

async fn insert_api_key(db: &Db, user_id: &str, plaintext: &str) {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    let hash = hash_api_key(plaintext).expect("hash api key");
    if let Db::Sqlite(pool) = db {
        sqlx::query(
            "INSERT INTO api_keys (id, user_id, name, key_hash, key_prefix, permissions, \
             inserted_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&id)
        .bind(user_id)
        .bind("test")
        .bind(&hash)
        .bind(&plaintext[..8.min(plaintext.len())])
        .bind("read,write")
        .bind(&now)
        .execute(pool)
        .await
        .expect("insert api_key");
    }
}

/// Attach the `WebState` extension to a request so the auth layer can
/// reach the DB and signers. The boot path attaches this at the
/// merged-router level; for tests we add it via a layer on the inner
/// router so each call sees a fresh state.
fn router_with_state(state: WebState) -> axum::Router {
    use axum::Extension;
    mydia_rs_web::api::v1::router().layer(Extension(state))
}

fn player_router_with_state(state: WebState) -> axum::Router {
    use axum::Extension;
    mydia_rs_web::api::player::v1::router().layer(Extension(state))
}

#[tokio::test]
async fn protected_route_returns_401_without_auth() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/indexers")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(parsed["error"].as_str().unwrap_or(""), "Unauthorized");
}

#[tokio::test]
async fn protected_route_returns_401_with_invalid_api_key() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/indexers")
                .header("X-API-Key", "mydia_wrong_key_99999999999999999")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn protected_route_accepts_valid_api_key_and_returns_501_marker() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    // download/job/.../status is still a 501-stub adapter — used here
    // so the test stays meaningful even as siblings (indexer, etc.)
    // get fully wired.
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/download/job/abc/status")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    assert!(
        parsed
            .get("todo")
            .and_then(|v| v.as_str())
            .is_some_and(|s| s.starts_with("U33.")),
        "missing U33 todo marker: {parsed}"
    );
}

#[tokio::test]
async fn protected_route_accepts_api_key_via_query_param() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let uri = format!("/api/v1/download/job/abc/status?api_key={}", fx.api_key);
    let response = router
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
}

#[tokio::test]
async fn playback_show_with_api_key_returns_default_progress() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/movie/00000000-0000-0000-0000-000000000000")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::OK);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("playback json");
    assert_eq!(parsed["position_seconds"], 0);
    assert_eq!(parsed["watched"], false);
}

// ---------- admin-only (`require_admin`) ----------

#[tokio::test]
async fn config_index_returns_401_without_auth() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/config")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn config_index_returns_403_for_non_admin_api_key() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/config")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(parsed["error"].as_str().unwrap_or(""), "Forbidden");
}

#[tokio::test]
async fn config_index_returns_default_payload_for_admin() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/config")
                .header("X-API-Key", &fx.admin_api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::OK);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("config index json");
    assert!(parsed.get("data").is_some(), "data key missing: {parsed}");
}

// ---------- media-token (`:media_api_auth`) ----------

#[tokio::test]
async fn stream_route_returns_401_without_auth() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/stream/file/abc")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn stream_route_accepts_media_token_bearer() {
    let fx = auth_fixture().await;
    let token = fx
        .media_signer
        .issue(
            "device-1",
            &fx.user_id,
            &[MediaTokenPermission::Stream],
            std::time::Duration::from_secs(3600),
        )
        .expect("issue media token");
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/stream/file/00000000-0000-0000-0000-000000000000")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    // The media-token verification passes; the handler then runs and
    // hits the DB looking for the media file. The fixture has no
    // media_files table, so we expect a 500 (db error) rather than a
    // 401, which proves the auth layer let the request through.
    assert!(
        response.status() == StatusCode::NOT_FOUND
            || response.status() == StatusCode::INTERNAL_SERVER_ERROR,
        "expected handler-level 404/500, got {}",
        response.status()
    );
}

#[tokio::test]
async fn stream_route_accepts_media_token_via_query_param() {
    let fx = auth_fixture().await;
    let token = fx
        .media_signer
        .issue(
            "device-1",
            &fx.user_id,
            &[MediaTokenPermission::Stream],
            std::time::Duration::from_secs(3600),
        )
        .expect("issue media token");
    let router = router_with_state(fx.state);
    let uri = format!("/api/v1/stream/file/00000000-0000-0000-0000-000000000000?token={token}");
    let response = router
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .expect("router oneshot");

    assert!(
        response.status() == StatusCode::NOT_FOUND
            || response.status() == StatusCode::INTERNAL_SERVER_ERROR,
        "expected handler-level 404/500, got {}",
        response.status()
    );
}

#[tokio::test]
async fn stream_route_rejects_expired_media_token() {
    let fx = auth_fixture().await;
    // TTL must be > 0 (issue rejects zero-duration), but with leeway=0
    // a one-second-old expired token reads as expired.
    let signer = MediaTokenSigner::new("test-guardian-secret-key-for-rest-tests", 0);
    // Manually build an expired claim by issuing 0-second TTL and
    // sleeping; or rely on the signer's behaviour at boundary.
    // Simpler: issue with a tiny TTL and sleep past it.
    let token = signer
        .issue(
            "device-1",
            &fx.user_id,
            &[MediaTokenPermission::Stream],
            std::time::Duration::from_secs(1),
        )
        .expect("issue token");
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/stream/file/abc")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn hls_route_returns_401_without_auth() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/hls/start")
                .method("POST")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

// ---------- player subtitle (`:api_auth`) ----------

#[tokio::test]
async fn player_v1_subtitle_returns_401_without_auth() {
    let fx = auth_fixture().await;
    let router = player_router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/player/v1/subtitles/movie/abc")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn player_v1_subtitle_index_returns_404_for_unknown_media() {
    let fx = auth_fixture().await;
    let router = player_router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/player/v1/subtitles/movie/00000000-0000-0000-0000-000000000000")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    // The fixture doesn't seed a media_files table, so the lookup
    // returns NoResult and the handler responds 500 — or 404 if the
    // table exists with no matches. The router itself accepted the
    // request (no auth failure) which is what we're verifying here.
    assert!(
        response.status() == StatusCode::NOT_FOUND
            || response.status() == StatusCode::INTERNAL_SERVER_ERROR,
        "expected 404/500, got {}",
        response.status()
    );
}

#[tokio::test]
async fn player_v1_subtitle_index_rejects_invalid_type() {
    let fx = auth_fixture().await;
    let router = player_router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/player/v1/subtitles/bogus/abc")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn player_v1_subtitle_show_remains_501_with_todo_marker() {
    let fx = auth_fixture().await;
    let router = player_router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/player/v1/subtitles/movie/abc/0")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(
        parsed["todo"].as_str().unwrap_or(""),
        "U33.player.subtitles.show"
    );
}

// ---------- wired adapters: download_client + indexer ----------

async fn insert_download_client(db: &Db, name: &str, kind: &str) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    if let Db::Sqlite(pool) = db {
        sqlx::query(
            "INSERT INTO download_client_configs \
             (id, name, type, enabled, priority, host, port, use_ssl, inserted_at, updated_at) \
             VALUES (?, ?, ?, 1, 1, 'localhost', 8080, 0, ?, ?)",
        )
        .bind(&id)
        .bind(name)
        .bind(kind)
        .bind(&now)
        .bind(&now)
        .execute(pool)
        .await
        .expect("insert download_client");
    }
    id
}

async fn insert_indexer(db: &Db, name: &str, kind: &str) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    if let Db::Sqlite(pool) = db {
        sqlx::query(
            "INSERT INTO indexer_configs \
             (id, name, type, enabled, priority, base_url, api_key, inserted_at, updated_at) \
             VALUES (?, ?, ?, 1, 1, 'https://indexer.test', 'secret-key', ?, ?)",
        )
        .bind(&id)
        .bind(name)
        .bind(kind)
        .bind(&now)
        .bind(&now)
        .execute(pool)
        .await
        .expect("insert indexer");
    }
    id
}

#[tokio::test]
async fn download_clients_index_returns_seeded_rows() {
    let fx = auth_fixture().await;
    insert_download_client(&fx.state.db, "qb-main", "qbittorrent").await;
    insert_download_client(&fx.state.db, "sab-main", "sabnzbd").await;

    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/downloads/clients")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::OK);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    let data = parsed["data"].as_array().expect("data array");
    assert_eq!(data.len(), 2);
    let names: Vec<&str> = data.iter().filter_map(|r| r["name"].as_str()).collect();
    assert!(names.contains(&"qb-main"));
    assert!(names.contains(&"sab-main"));
    assert_eq!(data[0]["health"]["status"], "unknown");
}

#[tokio::test]
async fn download_client_show_returns_detail() {
    let fx = auth_fixture().await;
    let id = insert_download_client(&fx.state.db, "qb-main", "qbittorrent").await;

    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/downloads/clients/{id}"))
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::OK);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(parsed["data"]["name"], "qb-main");
    assert_eq!(parsed["data"]["type"], "qbittorrent");
    assert_eq!(parsed["data"]["host"], "localhost");
    assert_eq!(parsed["data"]["port"], 8080);
}

#[tokio::test]
async fn download_client_show_returns_404_for_missing_id() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/downloads/clients/00000000-0000-0000-0000-000000000000")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn indexers_index_returns_seeded_rows() {
    let fx = auth_fixture().await;
    insert_indexer(&fx.state.db, "newznab-1", "newznab").await;

    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/indexers")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::OK);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    let data = parsed["data"].as_array().expect("data array");
    assert_eq!(data.len(), 1);
    assert_eq!(data[0]["name"], "newznab-1");
    assert_eq!(data[0]["health"]["status"], "unknown");
    // Summary view doesn't redact api_key — it's only in the detail view.
}

#[tokio::test]
async fn indexer_show_redacts_api_key() {
    let fx = auth_fixture().await;
    let id = insert_indexer(&fx.state.db, "newznab-1", "newznab").await;

    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/indexers/{id}"))
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::OK);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(parsed["data"]["name"], "newznab-1");
    assert_eq!(
        parsed["data"]["api_key"], "***",
        "indexer detail must redact api_key to mirror Phoenix"
    );
    // Confirm the raw secret never appears in the payload.
    let raw = String::from_utf8_lossy(&body);
    assert!(
        !raw.contains("secret-key"),
        "raw api key leaked in response: {raw}"
    );
}

#[tokio::test]
async fn indexer_show_returns_404_for_missing_id() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/indexers/00000000-0000-0000-0000-000000000000")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

// ---------- revoked / expired API key paths ----------

#[tokio::test]
async fn revoked_api_key_returns_401() {
    let fx = auth_fixture().await;
    // Revoke the user key.
    if let Db::Sqlite(pool) = &fx.state.db {
        let now = Utc::now().to_rfc3339();
        sqlx::query("UPDATE api_keys SET revoked_at = ? WHERE user_id = ?")
            .bind(&now)
            .bind(&fx.user_id)
            .execute(pool)
            .await
            .expect("revoke");
    }
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/indexers")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

// ---------------------------------------------------------------------
// HLS REST surface — U33 follow-up.
//
// The handlers delegate to `mydia_rs_streaming::Supervisor`, which the
// fixture builds once per test against a per-fixture tempdir. The
// happy-path tests use the DirectPlay branch (h264/aac inputs) so the
// runner exits immediately without invoking ffmpeg — production HLS
// transcoding is exercised by the streaming crate's own tests.
// ---------------------------------------------------------------------

async fn insert_media_file(db: &Db, h264_aac: bool) -> (String, tempfile::NamedTempFile) {
    use std::io::Write;
    let id = uuid::Uuid::new_v4().to_string();
    let media_item_id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    // Tempfile that lives for the test duration so the streaming
    // supervisor's input-path check passes.
    let mut file = tempfile::Builder::new()
        .prefix("u33-hls-input-")
        .suffix(".mp4")
        .tempfile()
        .expect("input fixture");
    file.write_all(b"fake-mp4-bytes").expect("write fixture");
    file.flush().expect("flush fixture");
    let path = file.path().to_string_lossy().into_owned();
    let (codec, audio_codec) = if h264_aac {
        ("h264", "aac")
    } else {
        ("hevc", "ac3")
    };

    if let Db::Sqlite(pool) = db {
        sqlx::query(
            "INSERT INTO media_files (id, media_item_id, path, codec, audio_codec, \
             analysis_attempts, inserted_at, updated_at) \
             VALUES (?, ?, ?, ?, ?, 0, ?, ?)",
        )
        .bind(&id)
        .bind(&media_item_id)
        .bind(&path)
        .bind(codec)
        .bind(audio_codec)
        .bind(&now)
        .bind(&now)
        .execute(pool)
        .await
        .expect("insert media_file");
    }
    (id, file)
}

#[tokio::test]
async fn hls_start_returns_401_without_auth() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/hls/start")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(r#"{"media_file_id":"abc"}"#))
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn hls_start_returns_404_for_unknown_media_file() {
    let fx = auth_fixture().await;
    let token = fx
        .media_signer
        .issue(
            "device-1",
            &fx.user_id,
            &[MediaTokenPermission::Stream],
            std::time::Duration::from_secs(3600),
        )
        .expect("issue media token");
    let router = router_with_state(fx.state);
    let body = serde_json::json!({
        "media_file_id": "00000000-0000-0000-0000-000000000000",
    });
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/hls/start")
                .header(header::CONTENT_TYPE, "application/json")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn hls_start_happy_path_returns_session_and_playlist_url() {
    let fx = auth_fixture().await;
    let (media_file_id, _input_keepalive) = insert_media_file(&fx.state.db, true).await;
    let token = fx
        .media_signer
        .issue(
            "device-1",
            &fx.user_id,
            &[MediaTokenPermission::Stream],
            std::time::Duration::from_secs(3600),
        )
        .expect("issue media token");

    let router = router_with_state(fx.state);
    let body = serde_json::json!({ "media_file_id": media_file_id });
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/hls/start")
                .header(header::CONTENT_TYPE, "application/json")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::OK);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    let session_id = parsed["session_id"].as_str().expect("session_id");
    assert!(
        uuid::Uuid::parse_str(session_id).is_ok(),
        "session_id is a valid uuid: {session_id}"
    );
    let url = parsed["master_playlist_url"]
        .as_str()
        .expect("master_playlist_url");
    assert_eq!(url, format!("/api/v1/hls/{session_id}/index.m3u8"));
    assert_eq!(parsed["status"], "ready");
}

#[tokio::test]
async fn hls_terminate_unknown_session_returns_200_not_found() {
    let fx = auth_fixture().await;
    let token = fx
        .media_signer
        .issue(
            "device-1",
            &fx.user_id,
            &[MediaTokenPermission::Stream],
            std::time::Duration::from_secs(3600),
        )
        .expect("issue media token");
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/api/v1/hls/00000000-0000-0000-0000-000000000000")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    // Phoenix shape: 200 with `status: "not_found"` so the player's
    // teardown path is idempotent (matches `HlsController.terminate_session`).
    assert_eq!(response.status(), StatusCode::OK);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(parsed["status"], "not_found");
}

#[tokio::test]
async fn hls_terminate_started_session_returns_terminated() {
    let fx = auth_fixture().await;
    let (media_file_id, _input_keepalive) = insert_media_file(&fx.state.db, true).await;
    let token = fx
        .media_signer
        .issue(
            "device-1",
            &fx.user_id,
            &[MediaTokenPermission::Stream],
            std::time::Duration::from_secs(3600),
        )
        .expect("issue media token");
    let router = router_with_state(fx.state.clone());
    let body = serde_json::json!({ "media_file_id": media_file_id });
    let start = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/hls/start")
                .header(header::CONTENT_TYPE, "application/json")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .expect("router oneshot");
    assert_eq!(start.status(), StatusCode::OK);
    let start_body = collect(start.into_body()).await;
    let start_parsed: serde_json::Value = serde_json::from_slice(&start_body).expect("json");
    let session_id = start_parsed["session_id"].as_str().expect("session_id");

    // Fresh router (the previous one was consumed by oneshot).
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/api/v1/hls/{session_id}"))
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::OK);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(parsed["status"], "terminated");
    assert_eq!(parsed["session_id"], session_id);
}

// ---------------------------------------------------------------------
// Operator probe-cache REST endpoints — download-clients (Slice 1) and
// indexers (Slice 2). The cache mock in `WebState` uses the default
// `ClientRegistry::with_defaults()` registry but the probe path will
// fail-fast in this test env (no real backend listening) so we only
// assert the wire shape, not the verdict.
// ---------------------------------------------------------------------

#[tokio::test]
async fn download_client_test_returns_401_without_auth() {
    let fx = auth_fixture().await;
    let id = insert_download_client(&fx.state.db, "qb-test", "qbittorrent").await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/v1/downloads/clients/{id}/test"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn download_client_test_returns_404_for_missing_id() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/downloads/clients/00000000-0000-0000-0000-000000000000/test")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(parsed["error"], "Download client not found");
}

#[tokio::test]
async fn download_client_test_returns_phoenix_shaped_health_payload() {
    let fx = auth_fixture().await;
    // `host=localhost:8080` (the insert helper) will fail to connect
    // since no qbittorrent is running. We only assert the wire shape
    // (status + checked_at + error fields all present).
    let id = insert_download_client(&fx.state.db, "qb-test", "qbittorrent").await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/v1/downloads/clients/{id}/test"))
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::OK);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    let data = &parsed["data"];
    let status = data["status"].as_str().unwrap_or("");
    assert!(
        status == "healthy" || status == "unhealthy",
        "status must be healthy/unhealthy, got {status:?}"
    );
    assert!(data["checked_at"].is_string(), "checked_at must be set");
    // The probe ran against a non-existent backend; expect unhealthy.
    assert_eq!(status, "unhealthy");
    assert!(data["error"].is_string(), "error must be set on failure");
}

#[tokio::test]
async fn download_clients_refresh_returns_202() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/downloads/clients/refresh")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::ACCEPTED);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(parsed["message"], "Health check refresh initiated");
}

#[tokio::test]
async fn download_clients_refresh_returns_401_without_auth() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/downloads/clients/refresh")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

// ---------- indexer probe-cache REST endpoints (Slice 2) ----------

#[tokio::test]
async fn indexer_test_returns_401_without_auth() {
    let fx = auth_fixture().await;
    let id = insert_indexer(&fx.state.db, "cardigann-1", "cardigann").await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/v1/indexers/{id}/test"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn indexer_test_returns_404_for_missing_id() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/indexers/00000000-0000-0000-0000-000000000000/test")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(parsed["error"], "Indexer not found");
}

#[tokio::test]
async fn indexer_test_returns_phoenix_shaped_health_for_unsupported_kind() {
    let fx = auth_fixture().await;
    // The seed helper inserts `type: "newznab"`, which doesn't map to
    // any AdapterKind variant; the probe path short-circuits with an
    // "unsupported kind" verdict (still 200, but `status: "unhealthy"`).
    let id = insert_indexer(&fx.state.db, "newznab-1", "newznab").await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/v1/indexers/{id}/test"))
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::OK);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    let data = &parsed["data"];
    assert_eq!(data["status"], "unhealthy");
    assert!(data["checked_at"].is_string(), "checked_at must be set");
    let err = data["error"].as_str().unwrap_or("");
    assert!(
        err.contains("unsupported indexer kind"),
        "unexpected error: {err}"
    );
}

#[tokio::test]
async fn indexer_test_known_kind_falls_through_to_probe_cache() {
    let fx = auth_fixture().await;
    // `cardigann` maps to a known kind; the cache has no adapter
    // registered (default registry is empty) so the probe returns
    // "no adapter registered" — still a Phoenix-shaped 200/unhealthy.
    let id = insert_indexer(&fx.state.db, "cardigann-1", "cardigann").await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/v1/indexers/{id}/test"))
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::OK);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    let data = &parsed["data"];
    assert_eq!(data["status"], "unhealthy");
    assert!(data["error"]
        .as_str()
        .unwrap_or("")
        .contains("no adapter registered"));
}

#[tokio::test]
async fn indexers_refresh_returns_202() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/indexers/refresh")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::ACCEPTED);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(parsed["message"], "Health check refresh initiated");
}

#[tokio::test]
async fn indexers_refresh_returns_401_without_auth() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/indexers/refresh")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn indexer_reset_failures_returns_200() {
    let fx = auth_fixture().await;
    let id = insert_indexer(&fx.state.db, "cardigann-1", "cardigann").await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/v1/indexers/{id}/reset-failures"))
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::OK);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(parsed["message"], "Failure counter reset successfully");
}

#[tokio::test]
async fn indexer_reset_failures_returns_404_for_missing_id() {
    let fx = auth_fixture().await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/indexers/00000000-0000-0000-0000-000000000000/reset-failures")
                .header("X-API-Key", &fx.api_key)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn indexer_reset_failures_returns_401_without_auth() {
    let fx = auth_fixture().await;
    let id = insert_indexer(&fx.state.db, "cardigann-1", "cardigann").await;
    let router = router_with_state(fx.state);
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/v1/indexers/{id}/reset-failures"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}
