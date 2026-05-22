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
use mydia_rs_db::Db;
use mydia_rs_jobs::storage::JobStorage;
use mydia_rs_jobs::workers::library_scanner::LibraryScannerArgs;
use mydia_rs_pubsub::Pubsub;
use mydia_rs_web::session::{self as web_session, SessionLayer};
use mydia_rs_web::WebState;
use sqlx::sqlite::SqlitePoolOptions;
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

async fn stub_state_and_session() -> (WebState, SessionLayer) {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("in-memory sqlite");
    let db = Db::Sqlite(pool);
    web_session::migrate(&db).await.expect("session migrate");
    let pubsub = Pubsub::new();
    let storage: JobStorage<LibraryScannerArgs> = JobStorage::from_db(&db);
    let session_layer = web_session::layer(&db, false);
    (WebState::new(db, pubsub, storage), session_layer)
}

async fn build() -> axum::Router {
    ensure_empty_public_dir();
    let (state, session_layer) = stub_state_and_session().await;
    build_router(state, session_layer)
}

#[tokio::test]
async fn home_page_serves_a_session_loading_shell() {
    // U24.a: AppShell guards the home page. An anonymous SSR pass
    // can't resolve current_user(), so it renders a small loading
    // shell server-side; the wasm hydration then bounces to /login.
    // This test pins the SSR shape so a future regression (white
    // page on cold load) gets caught even though the bounce itself
    // is a wasm-only behavior we can't reach from a tower oneshot.
    let router = build().await;
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

    // The AppShell guard renders one of these markers on SSR:
    //   - loading spinner (current_user resolving),
    //   - the drawer chrome (authenticated, won't happen on anon SSR).
    assert!(
        body.contains("loading-spinner") || body.contains("drawer"),
        "expected guard shell or drawer chrome:\n{body}"
    );
    assert!(
        body.contains("<title>mydia</title>"),
        "expected page title:\n{body}"
    );
}

#[tokio::test]
async fn login_page_renders_auth_card() {
    // U24.a auth surface — `/login` lives under AuthShell, no
    // session required, must render the form even on SSR.
    let router = build().await;
    let response = router
        .oneshot(
            Request::builder()
                .uri("/login")
                .body(Body::empty())
                .expect("build request"),
        )
        .await
        .expect("serve request");

    assert_eq!(response.status(), StatusCode::OK, "login page should 200");

    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("collect body");
    let body = String::from_utf8_lossy(&body);

    assert!(
        body.contains("Sign in to mydia"),
        "expected login heading:\n{body}"
    );
    assert!(
        body.contains(r#"id="login-form""#),
        "expected login form id:\n{body}"
    );
}

#[tokio::test]
async fn setup_page_renders_when_db_is_empty() {
    // With no users in the fixture DB, `/setup` should render the
    // first-time-setup form. Hydration's `setup_required()` check
    // confirms; SSR just emits the form.
    let router = build().await;
    let response = router
        .oneshot(
            Request::builder()
                .uri("/setup")
                .body(Body::empty())
                .expect("build request"),
        )
        .await
        .expect("serve request");

    assert_eq!(response.status(), StatusCode::OK, "setup page should 200");

    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("collect body");
    let body = String::from_utf8_lossy(&body);

    assert!(
        body.contains("Welcome to mydia"),
        "expected setup heading:\n{body}"
    );
    assert!(
        body.contains(r#"id="setup-form""#),
        "expected setup form id:\n{body}"
    );
}

#[tokio::test]
async fn security_headers_are_present_on_responses() {
    let router = build().await;
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
    let router = build().await;
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
