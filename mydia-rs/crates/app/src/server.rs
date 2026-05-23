//! axum + Dioxus router assembly.
//!
//! Builds the application router by composing:
//!   1. `dioxus::server::router(mydia_rs_web::app)` — SSR + asset
//!      pipeline + automatic registration of every `#[server]` /
//!      `#[get]` / `#[post]` macro in `mydia-rs-web`.
//!   2. Raw axum OIDC redirect handlers (`/auth/oidc/{login,callback}`)
//!      merged in before the layers attach, so the trace +
//!      catch-panic + request-id layers cover them too.
//!   3. Session middleware, then security headers (CSP / Referrer-
//!      Policy / X-Content-Type-Options / X-Frame-Options), request-id
//!      propagation, panic catching, compression, and trace.
//!
//! Listener + bind + graceful shutdown live in `dioxus::serve`, which
//! `main.rs` hands this Router to.
//!
//! Future units add: CORS allowlist construction from `ServerConfig`
//! (currently no CORS layer — the SPA is same-origin), authentication
//! middleware (U24), per-route rate limits (U28).

use axum::{Extension, Router};
use http::{HeaderName, HeaderValue};
use mydia_rs_web::api as web_api;
use mydia_rs_web::oidc as web_oidc;
use mydia_rs_web::session::SessionLayer;
use mydia_rs_web::{security, WebState};
use tower_http::catch_panic::CatchPanicLayer;
use tower_http::compression::CompressionLayer;
use tower_http::request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer};
use tower_http::set_header::SetResponseHeaderLayer;
use tower_http::trace::TraceLayer;

const REQUEST_ID_HEADER: HeaderName = HeaderName::from_static("x-request-id");

/// Build the axum Router for the running app.
///
/// `state` is wrapped in an `axum::Extension` so server functions and
/// WebSocket upgrade handlers in `mydia-rs-web` can pull it via
/// `FullstackContext::extension::<WebState>()`. `session_layer`
/// attaches the tower-sessions middleware so server fns can call
/// `Session::get/insert` for the authenticated user's id.
pub fn build_router(state: WebState, session_layer: SessionLayer) -> Router {
    let router = dioxus::server::router(mydia_rs_web::app);
    // The OIDC routes are raw axum GET handlers (302 redirects) —
    // they can't be Dioxus server fns because the login leg writes
    // PKCE state into the session before returning a redirect, and
    // the callback leg reads `code`/`state` from the query string.
    // Merge them in before the layers are attached so the trace +
    // catch-panic + request-id layers cover them too.
    let router = router.merge(web_oidc::router());
    // U33 REST API surface — `/api/v1/*` and `/api/player/v1/*`.
    // Mounted before the session layer attaches so the same trace +
    // request-id + catch-panic layers wrap every REST request, and so
    // the API key / media token extractor middleware (U33 follow-up)
    // can be hung off the same router level as the session layer.
    let router = router.merge(web_api::router(state.clone()));
    let router = session_layer.attach(router);

    // CSP picks dev or prod variant at build time. The dev variant
    // loosens script-src and style-src so dx serve's injected dev
    // HTML (Inter from fonts.googleapis.com, inlined dev-tool JS,
    // the hot-reload WebSocket client) doesn't trip a CSP violation
    // that kills the wasm client at startup. Release builds keep
    // the strict CSP.
    let csp = if cfg!(debug_assertions) {
        security::CONTENT_SECURITY_POLICY_DEV
    } else {
        security::CONTENT_SECURITY_POLICY_BASELINE
    };

    router
        .layer(Extension(state))
        .layer(SetResponseHeaderLayer::if_not_present(
            HeaderName::from_static("content-security-policy"),
            HeaderValue::from_static(csp),
        ))
        .layer(SetResponseHeaderLayer::if_not_present(
            HeaderName::from_static("referrer-policy"),
            HeaderValue::from_static(security::REFERRER_POLICY),
        ))
        .layer(SetResponseHeaderLayer::if_not_present(
            HeaderName::from_static("x-content-type-options"),
            HeaderValue::from_static(security::X_CONTENT_TYPE_OPTIONS),
        ))
        .layer(SetResponseHeaderLayer::if_not_present(
            HeaderName::from_static("x-frame-options"),
            HeaderValue::from_static(security::X_FRAME_OPTIONS),
        ))
        .layer(PropagateRequestIdLayer::new(REQUEST_ID_HEADER))
        .layer(SetRequestIdLayer::new(REQUEST_ID_HEADER, MakeRequestUuid))
        .layer(CatchPanicLayer::new())
        .layer(CompressionLayer::new())
        .layer(TraceLayer::new_for_http())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Once;

    fn ensure_empty_public_dir() {
        static INIT: Once = Once::new();
        INIT.call_once(|| {
            let dir = std::env::temp_dir().join("mydia-rs-ssr-test-public");
            std::fs::create_dir_all(&dir).expect("create empty public dir");
            // SAFETY: tests run in a fresh process; set_var here is
            // before any thread that reads DIOXUS_PUBLIC_PATH starts.
            unsafe {
                std::env::set_var("DIOXUS_PUBLIC_PATH", &dir);
            }
        });
    }

    #[test]
    fn build_router_compiles() {
        ensure_empty_public_dir();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("build runtime");
        let (state, session_layer) = runtime.block_on(test_state_and_session());
        let _router = build_router(state, session_layer);
    }

    async fn test_state_and_session() -> (WebState, SessionLayer) {
        use mydia_rs_db::Db;
        use mydia_rs_jobs::storage::JobStorage;
        use mydia_rs_jobs::workers::library_scanner::LibraryScannerArgs;
        use mydia_rs_pubsub::Pubsub;
        use mydia_rs_web::session;
        use sqlx::sqlite::SqlitePoolOptions;

        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .expect("in-memory sqlite");
        let db = Db::Sqlite(pool);
        session::migrate(&db).await.expect("tower-sessions migrate");
        let pubsub = Pubsub::new();
        let storage: JobStorage<LibraryScannerArgs> = JobStorage::from_db(&db);
        let session_layer = session::layer(&db, false);
        (WebState::new(db, pubsub, storage, None), session_layer)
    }
}
