//! Web security posture constants — CSP, header names, defaults.
//!
//! Per Key Technical Decisions in the plan, the actual `tower::Layer`
//! middleware is constructed in the parent `crates/app` (server side
//! only; wasm has no tower). This module carries the *constants and
//! defaults* both sides reference — header names so the CSP that's
//! served lines up with what the client expects, the cookie name that
//! differs from Phoenix's `_mydia_key` to avoid parallel-window
//! interference, and the default origin policy.
//!
//! The split keeps `crates/web` wasm-buildable (no tower-http) while
//! making the security posture testable as pure data.

// ---------- Session cookie ----------

/// Cookie name for the mydia-rs tower-sessions session. Deliberately
/// differs from Phoenix's `_mydia_key` so the two cookies don't
/// interfere during the parallel-window dogfooding period.
pub const SESSION_COOKIE_NAME: &str = "mydia_rs_session";

// ---------- Security headers ----------

pub const HEADER_X_FRAME_OPTIONS: &str = "X-Frame-Options";
pub const HEADER_X_CONTENT_TYPE_OPTIONS: &str = "X-Content-Type-Options";
pub const HEADER_REFERRER_POLICY: &str = "Referrer-Policy";
pub const HEADER_CONTENT_SECURITY_POLICY: &str = "Content-Security-Policy";

pub const X_FRAME_OPTIONS: &str = "SAMEORIGIN";
pub const X_CONTENT_TYPE_OPTIONS: &str = "nosniff";
pub const REFERRER_POLICY: &str = "strict-origin-when-cross-origin";

/// Baseline CSP compatible with Dioxus 0.7 SSR + hydration. The wasm
/// bundle is loaded from the same origin via the `dx`-managed asset
/// path so `script-src 'self'` is sufficient; `'wasm-unsafe-eval'` is
/// required for the wasm runtime to instantiate the module (modern
/// browsers gate `WebAssembly.instantiate` behind this directive).
/// `connect-src 'self'` covers server functions and WebSocket
/// subscriptions on the same origin.
pub const CONTENT_SECURITY_POLICY_BASELINE: &str = "default-src 'self'; \
    script-src 'self' 'wasm-unsafe-eval'; \
    style-src 'self' 'unsafe-inline'; \
    img-src 'self' data: https: blob:; \
    media-src 'self' blob:; \
    font-src 'self' data:; \
    connect-src 'self' ws: wss:; \
    frame-ancestors 'self'; \
    base-uri 'self'; \
    form-action 'self'";

/// Loosened CSP used by `cfg(debug_assertions)` builds (cargo run,
/// dx serve). The dev-mode dx wrapper injects:
///   - an inline `<style>` block that `@import`s Inter from
///     `fonts.googleapis.com`, so we need that origin on style-src
///     and the corresponding `fonts.gstatic.com` origin on font-src
///   - inline `<script>` blocks for dev-tools (toasts, hot-reload
///     bootstrapping), so script-src needs `'unsafe-inline'`
///   - the wasm hot-reload client connects to `ws://localhost:<dx_port>`,
///     which the existing `connect-src ws: wss:` already permits
///
/// Strict CSP returns in release builds via `CONTENT_SECURITY_POLICY_BASELINE`.
pub const CONTENT_SECURITY_POLICY_DEV: &str = "default-src 'self'; \
    script-src 'self' 'wasm-unsafe-eval' 'unsafe-inline' 'unsafe-eval'; \
    style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; \
    img-src 'self' data: https: blob:; \
    media-src 'self' blob:; \
    font-src 'self' data: https://fonts.gstatic.com; \
    connect-src 'self' ws: wss:; \
    frame-ancestors 'self'; \
    base-uri 'self'; \
    form-action 'self'";

/// `Returns` the default origin policy when the operator hasn't
/// configured one: trust only the configured `url_host` (Phoenix's
/// `check_origin` semantics — see `config/runtime.exs:125`).
///
/// `Returns` (scheme, host) pairs that should be added to the CORS
/// allow-list. mydia-rs uses an explicit allow-list per `ServerConfig`;
/// when the list is empty, the parent app builds the default from the
/// `url_scheme` + `url_host` config fields.
#[must_use]
pub fn default_origin(scheme: &str, host: &str) -> String {
    format!("{scheme}://{host}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cookie_name_differs_from_phoenix() {
        assert_ne!(SESSION_COOKIE_NAME, "_mydia_key");
        assert_eq!(SESSION_COOKIE_NAME, "mydia_rs_session");
    }

    #[test]
    fn security_header_constants_present() {
        assert_eq!(X_FRAME_OPTIONS, "SAMEORIGIN");
        assert_eq!(X_CONTENT_TYPE_OPTIONS, "nosniff");
        assert_eq!(REFERRER_POLICY, "strict-origin-when-cross-origin");
    }

    #[test]
    fn csp_baseline_allows_wasm() {
        // Dioxus hydration requires WebAssembly.instantiate, which
        // modern browsers gate behind 'wasm-unsafe-eval'.
        assert!(CONTENT_SECURITY_POLICY_BASELINE.contains("'wasm-unsafe-eval'"));
        assert!(CONTENT_SECURITY_POLICY_BASELINE.contains("connect-src 'self' ws: wss:"));
        assert!(CONTENT_SECURITY_POLICY_BASELINE.contains("frame-ancestors 'self'"));
    }

    #[test]
    fn default_origin_formats_scheme_host() {
        assert_eq!(
            default_origin("https", "mydia.example.com"),
            "https://mydia.example.com"
        );
        assert_eq!(
            default_origin("http", "localhost:4001"),
            "http://localhost:4001"
        );
    }
}
