//! The byte endpoints, exercised the way a video player exercises them.

mod support;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use mydia_server::test_support::app_over_library;
use tower::ServiceExt;

async fn get(
    app: axum::Router,
    uri: &str,
    token: &str,
    range: Option<&str>,
) -> axum::http::Response<Body> {
    let mut builder = Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));

    if let Some(range) = range {
        builder = builder.header("range", range);
    }

    app.oneshot(builder.body(Body::empty()).unwrap())
        .await
        .unwrap()
}

#[tokio::test]
async fn a_whole_file_request_returns_the_whole_file() {
    let media = support::movie_library().await;
    let (app, _guard, token) =
        app_over_library("admin", "adminadmin", media.path(), "movies").await;
    let file_id = support::first_file_id(app.clone(), &token).await;

    let response = get(
        app,
        &format!("/api/v1/stream/file/{file_id}?strategy=DIRECT_PLAY"),
        &token,
        None,
    )
    .await;

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["accept-ranges"], "bytes");
    assert_eq!(response.headers()["x-streaming-mode"], "direct");
    assert_eq!(response.headers()["content-type"], "video/mp4");

    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    assert!(!body.is_empty());
}

#[tokio::test]
async fn a_range_request_returns_exactly_that_range() {
    let media = support::movie_library().await;
    let (app, _guard, token) =
        app_over_library("admin", "adminadmin", media.path(), "movies").await;
    let file_id = support::first_file_id(app.clone(), &token).await;

    let response = get(
        app,
        &format!("/api/v1/stream/file/{file_id}?strategy=DIRECT_PLAY"),
        &token,
        Some("bytes=0-99"),
    )
    .await;

    assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(response.headers()["content-length"], "100");
    assert!(response.headers()["content-range"]
        .to_str()
        .unwrap()
        .starts_with("bytes 0-99/"));

    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    assert_eq!(body.len(), 100);
}

#[tokio::test]
async fn an_unsatisfiable_range_is_refused_with_the_file_size() {
    let media = support::movie_library().await;
    let (app, _guard, token) =
        app_over_library("admin", "adminadmin", media.path(), "movies").await;
    let file_id = support::first_file_id(app.clone(), &token).await;

    let response = get(
        app,
        &format!("/api/v1/stream/file/{file_id}"),
        &token,
        Some("bytes=99999999999-"),
    )
    .await;

    assert_eq!(response.status(), StatusCode::RANGE_NOT_SATISFIABLE);
    assert!(response.headers()["content-range"]
        .to_str()
        .unwrap()
        .starts_with("bytes */"));
}

#[tokio::test]
async fn an_unauthenticated_request_gets_nothing() {
    let media = support::movie_library().await;
    let (app, _guard, token) =
        app_over_library("admin", "adminadmin", media.path(), "movies").await;
    let file_id = support::first_file_id(app.clone(), &token).await;

    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/api/v1/stream/file/{file_id}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn a_query_token_authenticates_the_same_request() {
    // The claim-code transport, which no header-only implementation would
    // catch.
    let media = support::movie_library().await;
    let (app, _guard, token) =
        app_over_library("admin", "adminadmin", media.path(), "movies").await;
    let file_id = support::first_file_id(app.clone(), &token).await;

    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/api/v1/stream/file/{file_id}?token={token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn an_unknown_file_is_a_404() {
    let media = support::movie_library().await;
    let (app, _guard, token) =
        app_over_library("admin", "adminadmin", media.path(), "movies").await;

    let response = get(app, "/api/v1/stream/file/nope", &token, None).await;

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn the_remux_strategy_serves_fragmented_mp4() {
    let media = support::mkv_library().await;
    let (app, _guard, token) =
        app_over_library("admin", "adminadmin", media.path(), "movies").await;
    let file_id = support::first_file_id(app.clone(), &token).await;

    let response = get(
        app,
        &format!("/api/v1/stream/file/{file_id}?strategy=REMUX"),
        &token,
        None,
    )
    .await;

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["content-type"], "video/mp4");
    assert_eq!(response.headers()["x-streaming-mode"], "remux");

    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    // "ftyp" is the first box of any MP4. Its presence proves the pipe carried
    // a real container rather than an error message.
    assert_eq!(&body[4..8], b"ftyp");
}
