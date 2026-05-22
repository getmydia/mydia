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

use axum::Router;
use http::{HeaderName, HeaderValue};
use mydia_rs_config::Config;
use mydia_rs_web::security;
use tokio::net::TcpListener;
use tower_http::catch_panic::CatchPanicLayer;
use tower_http::compression::CompressionLayer;
use tower_http::request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer};
use tower_http::set_header::SetResponseHeaderLayer;
use tower_http::trace::TraceLayer;

const REQUEST_ID_HEADER: HeaderName = HeaderName::from_static("x-request-id");

/// Build the axum Router for the running app.
pub fn build_router() -> Router {
    let router = dioxus::server::router(mydia_rs_web::app);

    router
        .layer(SetResponseHeaderLayer::if_not_present(
            HeaderName::from_static("content-security-policy"),
            HeaderValue::from_static(security::CONTENT_SECURITY_POLICY_BASELINE),
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

    let listener = TcpListener::bind(addr).await?;
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
        let _router = build_router();
    }

    #[test]
    fn shutdown_grace_period_is_sane() {
        assert!(shutdown_grace_period() >= Duration::from_secs(1));
        assert!(shutdown_grace_period() <= Duration::from_secs(30));
    }
}
