//! Error taxonomy shared by every integration in this crate.
//!
//! Mirrors `mydia_rs_metadata::error::MetadataError` in spirit but stays
//! a separate type because the integration call sites care about
//! integration-specific failure modes (auth-refresh-required, scrobble
//! rejected, PIN pending) that do not exist in the metadata layer.

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Discriminant for [`IntegrationError`]. `snake_case` on the wire so
/// the GraphQL surface in U14 can map directly without translation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    /// Network-layer failure (DNS, TLS, connect-refused).
    Network,
    /// Request hit the configured timeout.
    Timeout,
    /// HTTP 4xx that is not specifically token-refresh-required.
    Client,
    /// HTTP 5xx.
    Server,
    /// 401/403 implying the user's access token needs refreshing.
    AuthExpired,
    /// 404 on a resource that should exist.
    NotFound,
    /// 429 rate-limit; caller should respect `retry_after`.
    RateLimited,
    /// Body parse or shape-mismatch failure.
    Parse,
    /// Caller misconfigured the integration (missing URL, missing token).
    InvalidConfig,
    /// Plex PIN flow: user has not yet authorized.
    PinPending,
    /// Plex PIN flow: PIN expired or was never created.
    PinExpired,
    /// Trakt device-code flow: still polling (HTTP 400 from `/oauth/device/token`).
    DevicePending,
    /// Trakt device-code flow: expired.
    DeviceExpired,
    /// Trakt device-code flow: user denied authorization.
    DeviceDenied,
    /// Trakt device-code flow: poll too fast.
    DeviceSlowDown,
    /// Catch-all.
    Unknown,
}

/// Structured error returned by every public method in this crate.
#[derive(Debug, Error, Clone)]
#[error("{kind:?}: {message}")]
pub struct IntegrationError {
    pub kind: ErrorKind,
    pub message: String,
    /// Optional HTTP status code (when the failure came from an HTTP
    /// response).
    pub status: Option<u16>,
    /// Optional `retry-after` seconds, set on `RateLimited`.
    pub retry_after: Option<u64>,
}

impl IntegrationError {
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
            status: None,
            retry_after: None,
        }
    }

    pub fn with_status(mut self, status: u16) -> Self {
        self.status = Some(status);
        self
    }

    pub fn with_retry_after(mut self, retry_after: u64) -> Self {
        self.retry_after = Some(retry_after);
        self
    }

    pub fn invalid_config(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::InvalidConfig, message)
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::NotFound, message)
    }

    pub fn auth_expired(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::AuthExpired, message)
    }

    pub fn network(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Network, message)
    }

    pub fn timeout(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Timeout, message)
    }

    pub fn parse(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Parse, message)
    }

    pub fn pin_pending() -> Self {
        Self::new(ErrorKind::PinPending, "PIN not yet authorized")
    }

    pub fn pin_expired() -> Self {
        Self::new(ErrorKind::PinExpired, "PIN expired or not found")
    }

    /// Map a non-success HTTP status to the right kind, picking up
    /// `retry_after` for 429.
    #[must_use]
    pub fn from_response_status(status: u16, retry_after: Option<u64>, body: Option<&str>) -> Self {
        let kind = match status {
            401 | 403 => ErrorKind::AuthExpired,
            404 => ErrorKind::NotFound,
            429 => ErrorKind::RateLimited,
            s if (500..600).contains(&s) => ErrorKind::Server,
            s if (400..500).contains(&s) => ErrorKind::Client,
            _ => ErrorKind::Unknown,
        };

        let mut message = match kind {
            ErrorKind::AuthExpired => format!("Authentication failed ({status})"),
            ErrorKind::NotFound => format!("Resource not found ({status})"),
            ErrorKind::RateLimited => format!("Rate limit exceeded ({status})"),
            ErrorKind::Server => format!("Upstream server error ({status})"),
            ErrorKind::Client => format!("Upstream client error ({status})"),
            _ => format!("Unexpected status {status}"),
        };
        if let Some(body) = body {
            // Keep the body excerpt small so logs don't blow up on a
            // verbose upstream error page.
            let excerpt: String = body.chars().take(200).collect();
            if !excerpt.is_empty() {
                message.push_str(": ");
                message.push_str(&excerpt);
            }
        }

        let mut err = Self::new(kind, message).with_status(status);
        if let Some(ra) = retry_after {
            err = err.with_retry_after(ra);
        }
        err
    }
}

impl From<reqwest::Error> for IntegrationError {
    fn from(err: reqwest::Error) -> Self {
        if err.is_timeout() {
            Self::timeout(format!("Request timed out: {err}"))
        } else if err.is_connect() {
            Self::network(format!("Connection failed: {err}"))
        } else if err.is_decode() {
            Self::parse(format!("Failed to decode response: {err}"))
        } else {
            Self::network(format!("Network error: {err}"))
        }
    }
}

impl From<serde_json::Error> for IntegrationError {
    fn from(err: serde_json::Error) -> Self {
        Self::parse(format!("JSON parse error: {err}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_response_status_routes_correctly() {
        assert_eq!(
            IntegrationError::from_response_status(401, None, None).kind,
            ErrorKind::AuthExpired
        );
        assert_eq!(
            IntegrationError::from_response_status(404, None, None).kind,
            ErrorKind::NotFound
        );
        assert_eq!(
            IntegrationError::from_response_status(429, Some(15), None).retry_after,
            Some(15)
        );
        assert_eq!(
            IntegrationError::from_response_status(503, None, None).kind,
            ErrorKind::Server
        );
    }

    #[test]
    fn body_excerpt_is_capped() {
        let big = "x".repeat(5_000);
        let err = IntegrationError::from_response_status(500, None, Some(&big));
        assert!(err.message.len() < 300);
    }
}
