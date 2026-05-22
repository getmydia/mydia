//! U22 SSR smoke tests — verify the axum + Dioxus router serves the
//! home page, renders layout chrome, and emits the security headers.
//!
//! These exercise the router via `tower::ServiceExt::oneshot` rather
//! than binding a TCP port, so they're hermetic and don't depend on
//! free ports. The `dioxus::server::router(app)` integration is what
//! we're verifying — if Dioxus regresses the SSR pipeline the home
//! request body would lose the layout chrome and these tests catch
//! it before a release ships.

use std::sync::Once;

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use mydia_rs_app::server::build_router;
use tower::ServiceExt;

/// `dioxus::server::router(app)` reads the `public/` directory next to
/// the test binary at construction time and panics if it's missing —
/// that directory is populated by `dx build` in a production flow.
/// For unit-style integration tests we hand it an empty temp dir via
/// `DIOXUS_PUBLIC_PATH` so the router builds without the wasm bundle.
fn ensure_empty_public_dir() {
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        let dir = std::env::temp_dir().join("mydia-rs-ssr-test-public");
        std::fs::create_dir_all(&dir).expect("create empty public dir");
        std::env::set_var("DIOXUS_PUBLIC_PATH", &dir);
    });
}

fn build() -> axum::Router {
    ensure_empty_public_dir();
    build_router()
}

#[tokio::test]
async fn home_page_renders_layout_chrome() {
    let router = build();
    let response = router
        .oneshot(
            Request::builder()
                .uri("/")
                .body(Body::empty())
                .expect("build request"),
        )
        .await
        .expect("serve request");

    assert_eq!(response.status(), StatusCode::OK, "home page should 200");

    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("collect body");
    let body = String::from_utf8_lossy(&body);

    // Layout chrome: the AppShell drawer, sidebar brand, and content
    // outlet should all render server-side. If hydration loses any of
    // these the page becomes a blank rectangle until the wasm bundle
    // loads — which is exactly the regression we want to catch.
    assert!(
        body.contains("drawer"),
        "expected drawer layout class:\n{body}"
    );
    assert!(body.contains("mydia-rs"), "expected page heading:\n{body}");
    assert!(
        body.contains("Smoke test"),
        "expected home-page smoke card:\n{body}"
    );
}

#[tokio::test]
async fn hello_page_renders_dynamic_param() {
    let router = build();
    let response = router
        .oneshot(
            Request::builder()
                .uri("/hello/mydia")
                .body(Body::empty())
                .expect("build request"),
        )
        .await
        .expect("serve request");

    assert_eq!(
        response.status(),
        StatusCode::OK,
        "hello page should 200 for valid path param"
    );

    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("collect body");
    let body = String::from_utf8_lossy(&body);

    assert!(
        body.contains("Hello, mydia!"),
        "expected dynamic name interpolation:\n{body}"
    );
}

#[tokio::test]
async fn security_headers_are_present_on_responses() {
    let router = build();
    let response = router
        .oneshot(
            Request::builder()
                .uri("/")
                .body(Body::empty())
                .expect("build request"),
        )
        .await
        .expect("serve request");

    let headers = response.headers();

    assert_eq!(
        headers.get("x-frame-options").and_then(|v| v.to_str().ok()),
        Some("SAMEORIGIN"),
        "X-Frame-Options must be SAMEORIGIN to allow same-origin embeds only"
    );
    assert_eq!(
        headers
            .get("x-content-type-options")
            .and_then(|v| v.to_str().ok()),
        Some("nosniff"),
        "X-Content-Type-Options must be nosniff"
    );
    assert_eq!(
        headers.get("referrer-policy").and_then(|v| v.to_str().ok()),
        Some("strict-origin-when-cross-origin"),
        "Referrer-Policy mismatch"
    );
    let csp = headers
        .get("content-security-policy")
        .and_then(|v| v.to_str().ok())
        .expect("CSP header should be present");
    assert!(
        csp.contains("'wasm-unsafe-eval'"),
        "CSP must allow wasm-unsafe-eval so Dioxus hydration can instantiate the wasm module: {csp}"
    );
    assert!(
        csp.contains("frame-ancestors 'self'"),
        "CSP must restrict frame-ancestors: {csp}"
    );
}

#[tokio::test]
async fn request_id_header_propagates() {
    let router = build();
    let response = router
        .oneshot(
            Request::builder()
                .uri("/")
                .body(Body::empty())
                .expect("build request"),
        )
        .await
        .expect("serve request");

    let request_id = response
        .headers()
        .get("x-request-id")
        .and_then(|v| v.to_str().ok())
        .expect("x-request-id header should be set by the propagate layer");

    assert!(
        !request_id.is_empty(),
        "x-request-id should be a non-empty uuid-shaped string"
    );
}
