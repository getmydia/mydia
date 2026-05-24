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
use mydia_rs_db::DatabaseConnection;
use mydia_rs_jobs::storage::JobStorage;
use mydia_rs_jobs::workers::library_scanner::LibraryScannerArgs;
use mydia_rs_pubsub::Pubsub;
use mydia_rs_web::session::{self as web_session, SessionLayer};
use mydia_rs_web::WebState;
use sea_orm::Database;
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
    let db: DatabaseConnection = Database::connect("sqlite::memory:")
        .await
        .expect("in-memory sqlite");
    web_session::migrate(&db).await.expect("session migrate");
    let pubsub = Pubsub::new();
    let storage: JobStorage<LibraryScannerArgs> = JobStorage::from_db(&db);
    let session_layer = web_session::layer(&db, false);
    (WebState::new(db, pubsub, storage, None), session_layer)
}

async fn build() -> axum::Router {
    ensure_empty_public_dir();
    let (state, session_layer) = stub_state_and_session().await;
    build_router(state, session_layer)
}

#[tokio::test]
async fn home_page_redirects_to_login_when_anonymous() {
    // U24.a: AppShell guards `/`. An anonymous SSR pass has no
    // `mydia_rs_session` cookie, so `current_user()` resolves to
    // `Ok(None)`. The guard then emits both a navigator push (which
    // re-routes the dioxus router server-side so SSR ends up
    // rendering the Login page directly) AND a `<meta http-equiv=
    // "refresh">` (the wasm-free fallback for browsers that
    // ignore the router state but follow the meta tag).
    //
    // The meta-refresh is the load-bearing piece for the
    // cargo-watch dev loop — `dx tools assets` ships only CSS, so
    // without it the user would sit on a spinner forever. The
    // re-routed Login page is the bonus.
    assert_anonymous_landing_redirects_to_login("/").await;
}

#[tokio::test]
async fn profile_route_redirects_anonymous_to_login() {
    // U24.d — `/profile` lives under AppShell with the same guard.
    assert_anonymous_landing_redirects_to_login("/profile").await;
}

#[tokio::test]
async fn discover_route_redirects_anonymous_to_login() {
    // U24.f — `/discover` lives under AppShell with the same guard.
    assert_anonymous_landing_redirects_to_login("/discover").await;
}

async fn assert_anonymous_landing_redirects_to_login(path: &str) {
    let router = build().await;
    let response = router
        .oneshot(
            Request::builder()
                .uri(path)
                .body(Body::empty())
                .expect("build request"),
        )
        .await
        .expect("serve request");

    assert_eq!(
        response.status(),
        StatusCode::OK,
        "{path} should 200 (meta-refresh handles the redirect, not the response code)"
    );

    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("collect body");
    let body = String::from_utf8_lossy(&body);

    assert!(
        body.contains("<title>mydia</title>"),
        "expected page title for {path}:\n{body}"
    );

    // Two paths both count as a successful anonymous redirect:
    //   1. The meta-refresh is in the head — the wasm-free fallback.
    //   2. The dioxus router re-rendered into the Login page after
    //      `nav.push(Route::Login{})` — which is what happens server-
    //      side because dioxus walks the router during SSR.
    // We assert that at least one is present. The meta-refresh is
    // the strictly load-bearing one; the re-render is icing.
    let has_meta_refresh =
        body.contains(r#"http-equiv="refresh""#) && body.contains(r#"content="0;url=/login""#);
    let has_login_form = body.contains(r#"id="login-form""#);
    assert!(
        has_meta_refresh || has_login_form,
        "expected meta-refresh OR login form on {path}:\n{body}"
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
async fn oidc_login_redirects_to_disabled_marker_when_oidc_off() {
    // U24.c — when no OidcContext is plumbed into WebState (the
    // stub fixture's default), GET /auth/oidc/login must return a
    // clean redirect to /login?error=oidc_disabled rather than
    // panicking or hanging on a missing client.
    let router = build().await;
    let response = router
        .oneshot(
            Request::builder()
                .uri("/auth/oidc/login")
                .body(Body::empty())
                .expect("build request"),
        )
        .await
        .expect("serve request");

    // axum::response::Redirect emits 303 See Other by default for
    // Redirect::to(...). Accept either 302 or 303 — the user-visible
    // behavior is identical.
    let status = response.status();
    assert!(
        status.is_redirection(),
        "expected redirect status, got {status}"
    );

    let location = response
        .headers()
        .get("location")
        .and_then(|v| v.to_str().ok())
        .expect("Location header on redirect");
    assert_eq!(location, "/login?error=oidc_disabled");
}

#[tokio::test]
async fn oidc_callback_redirects_to_disabled_marker_when_oidc_off() {
    // Symmetric to the login test: hitting /auth/oidc/callback with
    // OIDC disabled must not 500 or panic.
    let router = build().await;
    let response = router
        .oneshot(
            Request::builder()
                .uri("/auth/oidc/callback?code=xyz&state=abc")
                .body(Body::empty())
                .expect("build request"),
        )
        .await
        .expect("serve request");

    let status = response.status();
    assert!(
        status.is_redirection(),
        "expected redirect status, got {status}"
    );
    let location = response
        .headers()
        .get("location")
        .and_then(|v| v.to_str().ok())
        .expect("Location header on redirect");
    assert_eq!(location, "/login?error=oidc_disabled");
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
