//! Shared `reqwest` setup. Mirrors `lib/mydia/downloads/client/http.ex`.
//!
//! Phoenix wraps `Req` with a `new_request/1` helper that bakes in
//! the host/port/scheme + sensible timeouts. The Rust port does the
//! same, returning a `reqwest::Client` (or a `reqwest::ClientBuilder`
//! for adapters that need a cookie jar). Every per-adapter module
//! calls into this so the timeout / TLS / user-agent defaults live in
//! exactly one place.

use std::time::Duration;

use crate::error::DownloadError;

/// Default request timeout — matches Phoenix's `30_000ms` default.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

/// Default TCP connect timeout — matches Phoenix's `5_000ms`.
pub const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// `User-Agent` header value sent on every adapter call. Lets
/// operators identify mydia traffic in their client's access log.
pub const USER_AGENT: &str = concat!("mydia-rs/", env!("CARGO_PKG_VERSION"));

/// Build a fresh `reqwest::Client` with the standard timeout / TLS /
/// user-agent defaults. `cookie_store` is enabled — most adapters
/// don't use cookies, but qBittorrent does, and one extra `DashMap`
/// allocation per client is cheap.
pub fn build_client() -> Result<reqwest::Client, DownloadError> {
    reqwest::ClientBuilder::new()
        .timeout(DEFAULT_TIMEOUT)
        .connect_timeout(DEFAULT_CONNECT_TIMEOUT)
        .user_agent(USER_AGENT)
        .cookie_store(true)
        .build()
        .map_err(|e| DownloadError::Internal(format!("reqwest build failed: {e}")))
}
