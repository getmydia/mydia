//! Integration tests for the U33 REST API surface.
//!
//! Covers the load-bearing properties of the byte-range streaming
//! pipeline plus the scaffolded surface:
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
//! - Scaffolded routes return `501 Not Implemented` with a JSON body
//!   carrying the `todo` marker.
//! - Thumbnail / sprite paths sharded by checksum tier (covered in the
//!   unit tests of the thumbnail module).
//!
//! These tests deliberately avoid spinning up a database; they drive
//! the streaming branch via the `serve_file_for_tests` shim and the
//! scaffolded branches via the router merged through tower's
//! `ServiceExt::oneshot`. The DB-backed handlers' branches are
//! exercised by the broader integration smoke suite added in the
//! follow-up slice that fully wires `WebState`.

#![cfg(feature = "server")]

use std::io::Write;

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use http_body_util::BodyExt;
use mydia_rs_web::api;
use tower::ServiceExt;

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
    // The fixture is `i % 251`; byte 100 == 100, byte 199 == 199.
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

#[tokio::test]
async fn config_index_returns_default_payload() {
    // Build the v1 router without state — the config index endpoint
    // doesn't touch WebState today and returns the default payload
    // unconditionally. Once the config_settings repo ports, this test
    // adds a DB fixture; today it asserts the wire shape only.
    let router = mydia_rs_web::api::v1::router();
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/config")
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

#[tokio::test]
async fn scaffolded_endpoint_returns_501_with_todo_marker() {
    let router = mydia_rs_web::api::v1::router();
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/indexers")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("indexer 501 json");
    assert!(
        parsed
            .get("todo")
            .and_then(|v| v.as_str())
            .is_some_and(|s| s.starts_with("U33.")),
        "missing U33 todo marker: {parsed}"
    );
}

#[tokio::test]
async fn playback_show_returns_default_progress() {
    let router = mydia_rs_web::api::v1::router();
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/movie/00000000-0000-0000-0000-000000000000")
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

#[tokio::test]
async fn player_v1_subtitle_index_route_is_mounted() {
    let router = mydia_rs_web::api::player::v1::router();
    let response = router
        .oneshot(
            Request::builder()
                .uri("/api/player/v1/subtitles/movie/abc")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .expect("router oneshot");

    // The subtitle handler is scaffolded; the route must still be
    // reachable (not 404) so the player sees a well-defined response
    // shape, and the response must carry the U33 TODO marker.
    assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
    let body = collect(response.into_body()).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("subtitle 501 json");
    assert_eq!(
        parsed["todo"].as_str().unwrap_or(""),
        "U33.player.subtitles.index"
    );
}
