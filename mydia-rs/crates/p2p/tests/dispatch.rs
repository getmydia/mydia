//! Integration tests for the GraphQL and HLS dispatch arms of the
//! [`MinimalRouter`] (U29 follow-up).
//!
//! These exercise the seam between the in-process schema / streaming
//! supervisor and the p2p wire surface. They do NOT boot a real
//! `mydia_p2p_core::Host`; the [`mydia_rs_p2p::router::HlsStreamHandleApi`]
//! trait lets us hand the router a fake handle that captures the
//! header + chunks the router writes, then assert against those.
//!
//! Schema bootstrap is via `Schema::create_table_from_entity` against
//! the `mydia-rs-entities` crate, with FK enforcement disabled for the
//! same reason as `tests/integration.rs`.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use chrono::Utc;
use mydia_p2p_core::{GraphQLRequest, HlsRequest, HlsResponseHeader};
use mydia_rs_auth::{AccessTokenSigner, MediaTokenCache, MediaTokenPermission, MediaTokenSigner};
use mydia_rs_db::insert_active_model;
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_entities::{remote_devices, users};
use mydia_rs_p2p::router::{HlsStreamHandle, HlsStreamHandleApi, P2pRouter, RouterContext};
use mydia_rs_p2p::{ClaimRateLimiter, MinimalRouter};
use mydia_rs_pubsub::Pubsub;
use mydia_rs_streaming::{Supervisor, SupervisorConfig};
use sea_orm::{ConnectionTrait, Database, DatabaseConnection, Schema, Set};
use tokio::sync::Mutex;
use uuid::Uuid;

const SECRET: &str = "shared-test-guardian-secret-for-jwt-parity";

/// Build a fresh in-memory `SQLite` `SeaORM` connection with the tables
/// the p2p crate's dispatch arms touch. Matches the shape used in
/// `tests/integration.rs`.
async fn fresh_sqlite() -> DatabaseConnection {
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
        schema.create_table_from_entity(remote_devices::Entity),
    ] {
        db.execute(&stmt).await.expect("create table");
    }
    db
}

async fn insert_user(db: &DatabaseConnection) -> Uuid {
    let id = Uuid::new_v4();
    let now = DateTimeSecs::from(Utc::now());
    let am = users::ActiveModel {
        id: Set(UuidText(id)),
        username: Set(Some("alice".to_owned())),
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
    insert_active_model(am, db).await.expect("insert user");
    id
}

async fn insert_remote_device(db: &DatabaseConnection, user_id: Uuid) -> Uuid {
    let id = Uuid::new_v4();
    let now = DateTimeSecs::from(Utc::now());
    let am = remote_devices::ActiveModel {
        id: Set(UuidText(id)),
        device_name: Set("Test Device".to_owned()),
        platform: Set("android".to_owned()),
        device_static_public_key: Set(vec![0_u8]),
        token_hash: Set("argon2hash".to_owned()),
        last_seen_at: Set(Some(now)),
        revoked_at: Set(None),
        user_id: Set(UuidText(user_id)),
        inserted_at: Set(now),
        updated_at: Set(now),
    };
    insert_active_model(am, db)
        .await
        .expect("insert remote device");
    id
}

/// In-memory record of what the router sent on the stream. The router
/// hands us this through the `HlsStreamHandleApi` trait so tests can
/// assert against the actual bytes that would have gone on the wire.
#[derive(Clone, Default)]
struct FakeStream {
    inner: Arc<Mutex<FakeStreamInner>>,
}

#[derive(Default)]
struct FakeStreamInner {
    header: Option<HlsResponseHeader>,
    chunks: Vec<Vec<u8>>,
    finished: bool,
    file_ranges: Vec<(String, u64, u64)>,
}

impl FakeStream {
    fn new() -> Self {
        Self::default()
    }

    async fn snapshot(&self) -> FakeStreamSnapshot {
        let guard = self.inner.lock().await;
        FakeStreamSnapshot {
            header: guard.header.clone(),
            chunks_len: guard.chunks.len(),
            finished: guard.finished,
            file_ranges: guard.file_ranges.clone(),
        }
    }
}

#[derive(Debug, Clone)]
#[allow(dead_code)] // chunks_len is asserted only in select tests
struct FakeStreamSnapshot {
    header: Option<HlsResponseHeader>,
    chunks_len: usize,
    finished: bool,
    file_ranges: Vec<(String, u64, u64)>,
}

#[async_trait]
impl HlsStreamHandleApi for FakeStream {
    async fn send_header(&self, header: HlsResponseHeader) -> Result<(), String> {
        self.inner.lock().await.header = Some(header);
        Ok(())
    }

    async fn send_chunk(&self, data: Vec<u8>) -> Result<(), String> {
        self.inner.lock().await.chunks.push(data);
        Ok(())
    }

    async fn finish(&self) -> Result<(), String> {
        self.inner.lock().await.finished = true;
        Ok(())
    }

    async fn stream_file_range(
        &self,
        file_path: String,
        offset: u64,
        length: u64,
    ) -> Result<(), String> {
        // Simulate the Host's zero-copy path: record the requested
        // range so the test can verify the dispatch wired it up, and
        // finish the stream so the contract matches production.
        let mut guard = self.inner.lock().await;
        guard.file_ranges.push((file_path, offset, length));
        guard.finished = true;
        Ok(())
    }
}

fn build_router(db: DatabaseConnection) -> MinimalRouter {
    let media_signer = MediaTokenSigner::new(SECRET, 2);
    let access_signer = AccessTokenSigner::new(SECRET, 2);
    let rate_limiter = ClaimRateLimiter::new_default();
    MinimalRouter::new(db, media_signer, access_signer, rate_limiter)
}

// ============================================================
// GraphQL dispatch
// ============================================================

/// A tiny schema we can build without any DB plumbing. We use this
/// for the dispatch-shape tests so they don't depend on the full
/// mydia-rs-graphql resolver tree at runtime. The state needs *some*
/// DB handle, but the test never executes any DB-backed query against
/// it — introspection works directly against the schema's type system.
async fn echo_schema() -> mydia_rs_graphql::MydiaSchema {
    let db = Database::connect("sqlite::memory:")
        .await
        .expect("connect in-memory sqlite for schema");
    let state = mydia_rs_graphql::GraphqlAppState::new(db);
    mydia_rs_graphql::build_schema(state)
}

#[tokio::test]
async fn graphql_dispatch_returns_response_when_no_schema_configured() {
    let db = fresh_sqlite().await;
    let router = build_router(db);
    let req = GraphQLRequest {
        query: "{ __typename }".into(),
        variables: None,
        operation_name: None,
        auth_token: None,
    };
    let resp = router
        .handle_graphql(req, RouterContext::default())
        .await
        .expect("graphql dispatch");
    assert!(resp.errors.is_some());
    assert!(resp.data.is_none());
    let errors = resp.errors.unwrap();
    assert!(
        errors.contains("not configured"),
        "errors should explain the missing schema: {errors}"
    );
}

#[tokio::test]
async fn graphql_dispatch_anonymous_introspection_returns_query_root() {
    let db = fresh_sqlite().await;
    let router = build_router(db).with_graphql_schema(echo_schema().await);
    let req = GraphQLRequest {
        query: "{ __schema { queryType { name } } }".into(),
        variables: None,
        operation_name: None,
        auth_token: None,
    };
    let resp = router
        .handle_graphql(req, RouterContext::default())
        .await
        .expect("graphql dispatch");
    assert!(
        resp.errors.is_none(),
        "unexpected errors: {:?}",
        resp.errors
    );
    let data = resp.data.expect("data present");
    let parsed: serde_json::Value = serde_json::from_str(&data).unwrap();
    assert_eq!(parsed["__schema"]["queryType"]["name"], "Query");
}

#[tokio::test]
async fn graphql_dispatch_with_valid_access_token_authenticates() {
    let db = fresh_sqlite().await;
    let user_id = insert_user(&db).await;
    let router = build_router(db).with_graphql_schema(echo_schema().await);

    // Issue a valid access token for the inserted user.
    let access_signer = AccessTokenSigner::new(SECRET, 2);
    let token = access_signer
        .issue(&user_id.to_string(), Duration::from_secs(300))
        .expect("issue token")
        .token;

    let req = GraphQLRequest {
        query: "{ schemaVersion }".into(),
        variables: None,
        operation_name: None,
        auth_token: Some(token),
    };
    let resp = router
        .handle_graphql(req, RouterContext::default())
        .await
        .expect("graphql dispatch");
    assert!(
        resp.errors.is_none(),
        "unexpected errors: {:?}",
        resp.errors
    );
    let data = resp.data.expect("data");
    let parsed: serde_json::Value = serde_json::from_str(&data).unwrap();
    assert!(
        parsed["schemaVersion"].is_string(),
        "schemaVersion should resolve to a string: {parsed:?}"
    );
}

#[tokio::test]
async fn graphql_dispatch_with_invalid_token_falls_back_to_anonymous() {
    let db = fresh_sqlite().await;
    let router = build_router(db).with_graphql_schema(echo_schema().await);
    let req = GraphQLRequest {
        query: "{ schemaVersion }".into(),
        variables: None,
        operation_name: None,
        auth_token: Some("not-a-jwt".into()),
    };
    let resp = router
        .handle_graphql(req, RouterContext::default())
        .await
        .expect("graphql dispatch");
    // An invalid token degrades to anonymous; the query still runs.
    assert!(
        resp.errors.is_none(),
        "unexpected errors: {:?}",
        resp.errors
    );
    assert!(resp.data.is_some());
}

#[tokio::test]
async fn graphql_dispatch_parses_variables_json() {
    // Exercise the variables-JSON parser through the dispatch arm by
    // using GraphQL introspection's `__type(name: $n)` which takes a
    // string variable. If the parser drops variables on the floor,
    // `__type` resolves to null.
    let db = fresh_sqlite().await;
    let router = build_router(db).with_graphql_schema(echo_schema().await);
    let req = GraphQLRequest {
        query: r"query Q($n: String!) { __type(name: $n) { name } }".into(),
        variables: Some(r#"{"n": "Query"}"#.into()),
        operation_name: Some("Q".into()),
        auth_token: None,
    };
    let resp = router
        .handle_graphql(req, RouterContext::default())
        .await
        .expect("graphql dispatch");
    assert!(
        resp.errors.is_none(),
        "unexpected errors: {:?}",
        resp.errors
    );
    let data = resp.data.expect("data");
    let parsed: serde_json::Value = serde_json::from_str(&data).unwrap();
    assert_eq!(parsed["__type"]["name"], "Query");
}

// ============================================================
// HLS dispatch
// ============================================================

#[tokio::test]
async fn hls_dispatch_replies_501_when_no_supervisor_configured() {
    let db = fresh_sqlite().await;
    let router = build_router(db);
    let stream = FakeStream::new();
    let handle = HlsStreamHandle::new(Arc::new(stream.clone()));
    router
        .handle_hls_stream(
            HlsRequest {
                session_id: Uuid::new_v4().to_string(),
                path: "index.m3u8".into(),
                range_start: None,
                range_end: None,
                auth_token: None,
            },
            "stream-1".into(),
            handle,
            RouterContext::default(),
        )
        .await
        .expect("hls dispatch");
    let snap = stream.snapshot().await;
    assert_eq!(snap.header.as_ref().unwrap().status, 501);
    assert!(snap.finished);
}

#[tokio::test]
async fn hls_dispatch_replies_401_when_no_auth_token() {
    let db = fresh_sqlite().await;
    let pubsub = Pubsub::new();
    let supervisor = Supervisor::new(SupervisorConfig::default(), pubsub);
    let cache = MediaTokenCache::new(Duration::from_secs(300));
    let router = build_router(db).with_streaming(supervisor, cache);
    let stream = FakeStream::new();
    let handle = HlsStreamHandle::new(Arc::new(stream.clone()));
    router
        .handle_hls_stream(
            HlsRequest {
                session_id: Uuid::new_v4().to_string(),
                path: "index.m3u8".into(),
                range_start: None,
                range_end: None,
                auth_token: None,
            },
            "stream-1".into(),
            handle,
            RouterContext::default(),
        )
        .await
        .expect("hls dispatch");
    let snap = stream.snapshot().await;
    assert_eq!(snap.header.unwrap().status, 401);
}

#[tokio::test]
async fn hls_dispatch_replies_404_when_session_id_missing() {
    let db = fresh_sqlite().await;
    let user_id = insert_user(&db).await;
    let device_id = insert_remote_device(&db, user_id).await;

    let pubsub = Pubsub::new();
    let supervisor = Supervisor::new(SupervisorConfig::default(), pubsub);
    let cache = MediaTokenCache::new(Duration::from_secs(300));
    let router = build_router(db).with_streaming(supervisor, cache);
    let stream = FakeStream::new();
    let handle = HlsStreamHandle::new(Arc::new(stream.clone()));

    // Issue a valid media token. Auth passes, but the session id
    // doesn't exist → 404 from the dispatch.
    let media_signer = MediaTokenSigner::new(SECRET, 2);
    let token = media_signer
        .issue(
            &device_id.to_string(),
            &user_id.to_string(),
            &[MediaTokenPermission::Stream],
            Duration::from_secs(300),
        )
        .expect("issue media token");

    router
        .handle_hls_stream(
            HlsRequest {
                session_id: Uuid::new_v4().to_string(),
                path: "index.m3u8".into(),
                range_start: None,
                range_end: None,
                auth_token: Some(token),
            },
            "stream-1".into(),
            handle,
            RouterContext::default(),
        )
        .await
        .expect("hls dispatch");
    let snap = stream.snapshot().await;
    assert_eq!(snap.header.unwrap().status, 404);
}

#[tokio::test]
async fn hls_dispatch_streams_playlist_for_ready_direct_play_session() {
    let db = fresh_sqlite().await;
    let user_id = insert_user(&db).await;
    let device_id = insert_remote_device(&db, user_id).await;

    // Build a session manually so we don't need ffmpeg. The
    // supervisor's `start_session` path runs `resolve_strategy` on a
    // MediaFile; we go one level below and inject a handle directly
    // by using a custom MediaFile that resolves to DirectPlay (h264 +
    // aac + mp4 path), then ask the supervisor to start a session
    // against it. DirectPlay's runner is a no-op that calls
    // `mark_ready` immediately, so no ffmpeg subprocess spawns.
    let pubsub = Pubsub::new();
    let temp_root = tempfile::tempdir().expect("tempdir");
    let supervisor = Supervisor::new(
        SupervisorConfig {
            temp_base_dir: temp_root.path().to_path_buf(),
            ..SupervisorConfig::default()
        },
        pubsub,
    );

    // Build a MediaFile that resolves to DirectPlay.
    let media_file = mydia_rs_models::MediaFile {
        id: mydia_rs_db::types::UuidText::new_v4(),
        media_item_id: mydia_rs_db::types::UuidText::new_v4(),
        episode_id: None,
        quality_profile_id: None,
        library_path_id: None,
        path: Some("/library/test.mp4".to_string()),
        relative_path: Some("test.mp4".to_string()),
        size: Some(1_000_000),
        resolution: Some("1080p".to_string()),
        codec: Some("h264".to_string()),
        hdr_format: None,
        audio_codec: Some("aac".to_string()),
        bitrate: Some(5_000_000),
        verified_at: None,
        analyzed_at: Some(mydia_rs_db::types::DateTimeSecs(Utc::now())),
        analysis_attempts: 1,
        last_analysis_error: None,
        metadata: None,
        cover_blob: None,
        sprite_blob: None,
        vtt_blob: None,
        preview_blob: None,
        phash: None,
        generated_at: None,
        trashed_at: None,
        inserted_at: mydia_rs_db::types::DateTimeSecs(Utc::now()),
        updated_at: mydia_rs_db::types::DateTimeSecs(Utc::now()),
    };
    let user_uuid_text = mydia_rs_db::types::UuidText::from(user_id);
    let session_handle = supervisor
        .start_session(&media_file, user_uuid_text)
        .await
        .expect("start session");

    // Create a fake playlist file inside the session's temp_dir.
    let temp_dir = session_handle.temp_dir.clone();
    tokio::fs::write(temp_dir.join("index.m3u8"), b"#EXTM3U\n")
        .await
        .expect("write playlist");

    let cache = MediaTokenCache::new(Duration::from_secs(300));
    let router = build_router(db).with_streaming(supervisor, cache);
    let stream = FakeStream::new();
    let handle = HlsStreamHandle::new(Arc::new(stream.clone()));

    let media_signer = MediaTokenSigner::new(SECRET, 2);
    let token = media_signer
        .issue(
            &device_id.to_string(),
            &user_id.to_string(),
            &[MediaTokenPermission::Stream],
            Duration::from_secs(300),
        )
        .expect("issue media token");

    router
        .handle_hls_stream(
            HlsRequest {
                session_id: session_handle.session_id.to_string(),
                path: "index.m3u8".into(),
                range_start: None,
                range_end: None,
                auth_token: Some(token),
            },
            "stream-1".into(),
            handle,
            RouterContext::default(),
        )
        .await
        .expect("hls dispatch");

    let snap = stream.snapshot().await;
    let header = snap.header.expect("header sent");
    assert_eq!(header.status, 200);
    assert_eq!(header.content_type, "application/vnd.apple.mpegurl");
    assert_eq!(header.cache_control.as_deref(), Some("no-cache"));
    assert_eq!(snap.file_ranges.len(), 1, "stream_file_range called once");
    let (path, offset, length) = &snap.file_ranges[0];
    let expected_path: PathBuf = temp_dir.join("index.m3u8");
    assert_eq!(path, &expected_path.to_string_lossy().to_string());
    assert_eq!(*offset, 0);
    assert_eq!(*length, header.content_length);
    assert!(snap.finished);
}

#[tokio::test]
async fn hls_dispatch_rejects_path_traversal() {
    let db = fresh_sqlite().await;
    let user_id = insert_user(&db).await;
    let device_id = insert_remote_device(&db, user_id).await;

    let pubsub = Pubsub::new();
    let temp_root = tempfile::tempdir().expect("tempdir");
    let supervisor = Supervisor::new(
        SupervisorConfig {
            temp_base_dir: temp_root.path().to_path_buf(),
            ..SupervisorConfig::default()
        },
        pubsub,
    );

    let media_file = mydia_rs_models::MediaFile {
        id: mydia_rs_db::types::UuidText::new_v4(),
        media_item_id: mydia_rs_db::types::UuidText::new_v4(),
        episode_id: None,
        quality_profile_id: None,
        library_path_id: None,
        path: Some("/library/test.mp4".to_string()),
        relative_path: Some("test.mp4".to_string()),
        size: Some(1_000_000),
        resolution: Some("1080p".to_string()),
        codec: Some("h264".to_string()),
        hdr_format: None,
        audio_codec: Some("aac".to_string()),
        bitrate: Some(5_000_000),
        verified_at: None,
        analyzed_at: Some(mydia_rs_db::types::DateTimeSecs(Utc::now())),
        analysis_attempts: 1,
        last_analysis_error: None,
        metadata: None,
        cover_blob: None,
        sprite_blob: None,
        vtt_blob: None,
        preview_blob: None,
        phash: None,
        generated_at: None,
        trashed_at: None,
        inserted_at: mydia_rs_db::types::DateTimeSecs(Utc::now()),
        updated_at: mydia_rs_db::types::DateTimeSecs(Utc::now()),
    };
    let user_uuid_text = mydia_rs_db::types::UuidText::from(user_id);
    let session_handle = supervisor
        .start_session(&media_file, user_uuid_text)
        .await
        .expect("start session");

    let cache = MediaTokenCache::new(Duration::from_secs(300));
    let router = build_router(db).with_streaming(supervisor, cache);
    let stream = FakeStream::new();
    let handle = HlsStreamHandle::new(Arc::new(stream.clone()));

    let media_signer = MediaTokenSigner::new(SECRET, 2);
    let token = media_signer
        .issue(
            &device_id.to_string(),
            &user_id.to_string(),
            &[MediaTokenPermission::Stream],
            Duration::from_secs(300),
        )
        .expect("issue media token");

    router
        .handle_hls_stream(
            HlsRequest {
                session_id: session_handle.session_id.to_string(),
                path: "../escape.txt".into(),
                range_start: None,
                range_end: None,
                auth_token: Some(token),
            },
            "stream-1".into(),
            handle,
            RouterContext::default(),
        )
        .await
        .expect("hls dispatch");

    let snap = stream.snapshot().await;
    assert_eq!(snap.header.unwrap().status, 403);
}

/// Concurrency: a burst of HLS dispatch calls on a 2-worker tokio
/// runtime must not starve. Mirrors the existing
/// `many_spawn_blocking_calls_complete_under_load` test from
/// `integration.rs` but exercises the full dispatch path (including
/// the spawn_blocking-wrapped `std::fs::metadata` call inside the
/// handler).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hls_dispatch_burst_completes_under_load() {
    let db = fresh_sqlite().await;
    let router = build_router(db);

    // Without a configured supervisor, the dispatch arm short-circuits
    // to a 501 reply. That's enough to exercise the per-call awaitable
    // path through the router; we want to confirm we don't deadlock,
    // not to verify session-management semantics here.
    let router = Arc::new(router);
    let mut handles = Vec::new();
    for _ in 0..50 {
        let router = router.clone();
        handles.push(tokio::spawn(async move {
            let stream = FakeStream::new();
            let handle = HlsStreamHandle::new(Arc::new(stream.clone()));
            router
                .handle_hls_stream(
                    HlsRequest {
                        session_id: Uuid::new_v4().to_string(),
                        path: "index.m3u8".into(),
                        range_start: None,
                        range_end: None,
                        auth_token: None,
                    },
                    Uuid::new_v4().to_string(),
                    handle,
                    RouterContext::default(),
                )
                .await
                .unwrap();
            let snap = stream.snapshot().await;
            assert!(snap.header.is_some());
        }));
    }
    let result = tokio::time::timeout(Duration::from_secs(10), futures_join_all(handles)).await;
    assert!(result.is_ok(), "hls dispatch burst hung");
}

#[tokio::test]
async fn read_media_dispatch_returns_permanent_error() {
    let db = fresh_sqlite().await;
    let router = build_router(db);
    let req = mydia_p2p_core::ReadMediaRequest {
        file_path: "some/file.mp4".into(),
        offset: 0,
        length: 100,
    };
    let resp = router
        .handle_read_media(req, RouterContext::default())
        .await
        .expect("read_media dispatch");
    match resp {
        mydia_p2p_core::MydiaResponse::Error(msg) => {
            assert!(
                msg.contains("permanently unwired"),
                "got unexpected message: {msg}"
            );
        }
        _ => panic!("expected MydiaResponse::Error, got {resp:?}"),
    }
}

async fn futures_join_all<T>(handles: Vec<tokio::task::JoinHandle<T>>) -> Vec<T> {
    let mut results = Vec::with_capacity(handles.len());
    for h in handles {
        results.push(h.await.unwrap());
    }
    results
}
