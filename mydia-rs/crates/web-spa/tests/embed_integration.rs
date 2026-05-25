use axum::body::Body;
use http::Request;
use http_body_util::BodyExt;
use mydia_rs_web_spa::embed::spa_router;
use tower::ServiceExt;

fn app() -> axum::Router {
    spa_router()
}

#[tokio::test]
async fn serves_index_html_at_root() {
    let app = app();

    let response = app
        .oneshot(Request::get("/").body(Body::empty()).unwrap())
        .await
        .unwrap();

    assert_eq!(response.status(), 200);
    let body = collect_body(response).await;
    assert!(
        body.contains("Mydia"),
        "root should serve index.html containing 'Mydia'"
    );
}

#[tokio::test]
async fn serves_css_with_content_type() {
    let app = app();

    let response = app
        .oneshot(
            Request::get("/assets/index-BKn82LfP.css")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), 200);
    let content_type = response
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(
        content_type.contains("css"),
        "CSS file should have text/css content-type, got: {content_type}"
    );
}

#[tokio::test]
async fn spa_fallback_serves_index_html_for_unknown_routes() {
    let app = app();

    // Client-side route that doesn't correspond to an on-disk file should
    // receive index.html (SPA fallback) so react-router can handle it.
    let response = app
        .oneshot(
            Request::get("/admin/library-paths")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), 200);
    let body = collect_body(response).await;
    assert!(
        body.contains("Mydia"),
        "SPA fallback should return index.html for unknown routes"
    );
}

#[tokio::test]
async fn returns_etag_header() {
    let app = app();

    let response = app
        .oneshot(Request::get("/").body(Body::empty()).unwrap())
        .await
        .unwrap();

    let etag = response.headers().get("etag").and_then(|v| v.to_str().ok());
    assert!(etag.is_some(), "response should include ETag header");
}

/// Helper: collect the full response body into a String.
async fn collect_body(response: axum::response::Response) -> String {
    let body = response.into_body();
    let bytes = body.collect().await.unwrap().to_bytes();
    String::from_utf8_lossy(&bytes).into_owned()
}
