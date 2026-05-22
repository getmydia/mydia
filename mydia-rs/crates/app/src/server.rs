//! axum + Dioxus server mount.
//!
//! Builds the application router by composing:
//!   1. `dioxus::server::router(mydia_rs_web::app)` — SSR + asset
//!      pipeline + automatic registration of every `#[server]` /
//!      `#[get]` / `#[post]` macro in `mydia-rs-web`.
//!   2. Security middleware layers from `mydia_rs_web::security` —
//!      header constants live in the wasm-buildable crate; the
//!      `tower::Layer` construction lives here because tower-http is
//!      a server-only dep.
//!   3. Trace + catch-panic + request-id + compression layers so
//!      handler panics log with a backtrace and return 500 instead
//!      of dropping the connection, and every request gets an
//!      `x-request-id` for log correlation.
//!
//! Future units add: CORS allowlist construction from `ServerConfig`
//! (currently no CORS layer — the SPA is same-origin), authentication
//! middleware (U24), per-route rate limits (U28).

use std::future::Future;
use std::net::SocketAddr;
use std::time::Duration;

use axum::{Extension, Router};
use http::{HeaderName, HeaderValue};
use mydia_rs_config::Config;
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
/// `FullstackContext::extension::<WebState>()`.
pub fn build_router(state: WebState) -> Router {
    let router = dioxus::server::router(mydia_rs_web::app);

    // CSP picks dev or prod variant at build time. The dev variant
    // loosens script-src and style-src so dx serve's injected dev
    // HTML (which pulls Inter from fonts.googleapis.com and inlines
    // its dev-tool JS) doesn't trip a CSP violation that kills the
    // wasm client at startup. Release builds keep the strict CSP.
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

/// Bind to the configured `host:port` and serve until shutdown.
///
/// The caller owns the runtime; we don't use `dioxus::serve` because
/// the existing bootstrap (config → tracing → DB → schema check →
/// runtime lock) needs to run before the server starts, and
/// `dioxus::serve` would build its own runtime.
pub async fn serve<F>(config: &Config, router: Router, shutdown: F) -> std::io::Result<()>
where
    F: Future<Output = ()> + Send + 'static,
{
    let addr: SocketAddr = format!("{}:{}", config.server.host, config.server.port)
        .parse()
        .map_err(|err| std::io::Error::new(std::io::ErrorKind::InvalidInput, err))?;

    // Bind via TcpSocket so we can set SO_REUSEADDR before listen.
    // Without it, a hot-rebuild restart hits the kernel's TIME_WAIT
    // window for ~60s and the new binary fails with "Address already
    // in use". With it, the port is reusable immediately. Safe in
    // production too — SO_REUSEADDR doesn't allow two listeners on
    // the same port simultaneously, only reuse of TIME_WAIT sockets.
    let socket = match addr {
        SocketAddr::V4(_) => tokio::net::TcpSocket::new_v4()?,
        SocketAddr::V6(_) => tokio::net::TcpSocket::new_v6()?,
    };
    socket.set_reuseaddr(true)?;
    socket.bind(addr)?;
    let listener = socket.listen(1024)?;
    let local_addr = listener.local_addr()?;
    tracing::info!(
        addr = %local_addr,
        "axum + Dioxus SSR listening (U22 scaffolding)"
    );

    axum::serve(listener, router)
        .with_graceful_shutdown(shutdown)
        .await
}

/// Tests reach for a short shutdown deadline so a stuck handler can't
/// keep CI hanging.
#[must_use]
pub fn shutdown_grace_period() -> Duration {
    Duration::from_secs(5)
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
            std::env::set_var("DIOXUS_PUBLIC_PATH", &dir);
        });
    }

    #[test]
    fn build_router_compiles() {
        ensure_empty_public_dir();
        // We construct a stub state in-memory; the router is built but
        // not served, so no DB / pubsub traffic flows.
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("build runtime");
        let state = runtime.block_on(test_state());
        let _router = build_router(state);
    }

    async fn test_state() -> WebState {
        use mydia_rs_db::Db;
        use mydia_rs_jobs::storage::JobStorage;
        use mydia_rs_jobs::workers::library_scanner::LibraryScannerArgs;
        use mydia_rs_pubsub::Pubsub;
        use sqlx::sqlite::SqlitePoolOptions;

        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .expect("open in-memory sqlite");
        let db = Db::Sqlite(pool);
        let pubsub = Pubsub::new();
        // Migration not needed for build_router_compiles — we never push.
        let storage: JobStorage<LibraryScannerArgs> = JobStorage::from_db(&db);
        WebState::new(db, pubsub, storage)
    }

    #[test]
    fn shutdown_grace_period_is_sane() {
        assert!(shutdown_grace_period() >= Duration::from_secs(1));
        assert!(shutdown_grace_period() <= Duration::from_secs(30));
    }
}
