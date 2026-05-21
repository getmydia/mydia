//! Error taxonomy for metadata provider operations.
//!
//! Mirrors `lib/mydia/metadata/provider/error.ex`. Every Rust variant
//! corresponds to one Elixir `:atom` so the wire-level error semantics
//! line up across the parallel Phoenix and Rust runtimes during U34's
//! cross-version compatibility window.
//!
//! Conversion from a [`reqwest::Error`] is implemented via `From` and
//! [`MetadataError::from_response_status`] so adapters can route any
//! transport- or HTTP-layer failure into the same enum without
//! reaching for inspection helpers.

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Discriminant for [`MetadataError`]. Equivalent to the Elixir
/// `error_type` union; serializes to `snake_case` for parity with
/// `Atom.to_string/1` on the Phoenix side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    /// Unable to connect to the provider (refused, host unreachable).
    ConnectionFailed,
    /// Invalid credentials / 401 / 403.
    AuthenticationFailed,
    /// Request exceeded the configured timeout.
    Timeout,
    /// Resource is absent (HTTP 404, empty result envelope).
    NotFound,
    /// HTTP 429 — caller should respect `retry_after` if present.
    RateLimited,
    /// Caller provided an invalid query / parameter.
    InvalidRequest,
    /// Caller's configuration is malformed (missing `base_url`, etc.).
    InvalidConfig,
    /// Generic upstream API error (HTTP 4xx/5xx not covered by the
    /// more specific variants).
    ApiError,
    /// Network-layer error (DNS, TLS, transport).
    Network,
    /// Failed to parse the response body.
    ParseError,
    /// Unknown / unclassified.
    Unknown,
}

impl ErrorKind {
    /// Human-readable label, used in the `Display` impl.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::ConnectionFailed => "Connection failed",
            Self::AuthenticationFailed => "Authentication failed",
            Self::Timeout => "Timeout",
            Self::NotFound => "Not found",
            Self::RateLimited => "Rate limited",
            Self::InvalidRequest => "Invalid request",
            Self::InvalidConfig => "Invalid config",
            Self::ApiError => "API error",
            Self::Network => "Network error",
            Self::ParseError => "Parse error",
            Self::Unknown => "Unknown",
        }
    }
}

/// Structured error returned by every [`crate::Provider`] method.
///
/// `details` carries optional context (HTTP status, response body, the
/// `retry-after` value for `RateLimited`). It is an opaque JSON value
/// rather than a typed sub-struct because the Elixir source treats it
/// as a free-form `map() | nil` and downstream code only ever inspects
/// individual keys (`status`, `retry_after`, `body`).
#[derive(Debug, Error, Clone)]
#[error("{}: {message}", kind.label())]
pub struct MetadataError {
    /// Variant discriminant.
    pub kind: ErrorKind,
    /// Operator-facing message.
    pub message: String,
    /// Optional structured context; carried as JSON to avoid coupling
    /// to per-call-site struct shapes.
    pub details: Option<serde_json::Value>,
}

impl MetadataError {
    /// Construct an error with explicit kind, message, and optional details.
    #[must_use]
    pub fn new(
        kind: ErrorKind,
        message: impl Into<String>,
        details: Option<serde_json::Value>,
    ) -> Self {
        Self {
            kind,
            message: message.into(),
            details,
        }
    }

    /// `ConnectionFailed`.
    pub fn connection_failed(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::ConnectionFailed, message, None)
    }

    /// `AuthenticationFailed`.
    pub fn authentication_failed(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::AuthenticationFailed, message, None)
    }

    /// `Timeout`.
    pub fn timeout(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Timeout, message, None)
    }

    /// `NotFound`.
    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::NotFound, message, None)
    }

    /// `RateLimited`, optionally carrying a `retry_after` seconds hint.
    pub fn rate_limited(message: impl Into<String>, retry_after: Option<u64>) -> Self {
        let details = retry_after.map(|s| serde_json::json!({ "retry_after": s, "status": 429 }));
        Self::new(ErrorKind::RateLimited, message, details)
    }

    /// `InvalidRequest`.
    pub fn invalid_request(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::InvalidRequest, message, None)
    }

    /// `InvalidConfig`.
    pub fn invalid_config(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::InvalidConfig, message, None)
    }

    /// `ApiError` with an HTTP status code.
    pub fn api_error(message: impl Into<String>, status: u16) -> Self {
        Self::new(
            ErrorKind::ApiError,
            message,
            Some(serde_json::json!({ "status": status })),
        )
    }

    /// `Network`.
    pub fn network(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Network, message, None)
    }

    /// `ParseError`.
    pub fn parse_error(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::ParseError, message, None)
    }

    /// `Unknown`.
    pub fn unknown(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Unknown, message, None)
    }

    /// Map a non-success HTTP status (`>= 400`) to the appropriate
    /// variant. Mirrors `Error.from_req_error/1` for `Req.Response`.
    ///
    /// `retry_after_seconds` carries the parsed `retry-after` header
    /// for the 429 path; pass `None` if not present or unparseable.
    #[must_use]
    pub fn from_response_status(
        status: u16,
        retry_after_seconds: Option<u64>,
        body_excerpt: Option<&str>,
    ) -> Self {
        let kind = match status {
            401 | 403 => ErrorKind::AuthenticationFailed,
            404 => ErrorKind::NotFound,
            429 => ErrorKind::RateLimited,
            s if s >= 400 => ErrorKind::ApiError,
            _ => ErrorKind::Unknown,
        };

        let message = match kind {
            ErrorKind::AuthenticationFailed => format!("Authentication failed ({status})"),
            ErrorKind::NotFound => format!("Resource not found ({status})"),
            ErrorKind::RateLimited => format!("Rate limit exceeded ({status})"),
            ErrorKind::ApiError => format!("HTTP error ({status})"),
            _ => format!("Unexpected status {status}"),
        };

        let mut details = serde_json::Map::new();
        details.insert("status".into(), serde_json::Value::from(status));
        if let Some(ra) = retry_after_seconds {
            details.insert("retry_after".into(), serde_json::Value::from(ra));
        }
        if let Some(body) = body_excerpt {
            details.insert("body".into(), serde_json::Value::from(body));
        }

        Self::new(kind, message, Some(serde_json::Value::Object(details)))
    }

    /// Optional `retry_after` (seconds) for `RateLimited`.
    #[must_use]
    pub fn retry_after(&self) -> Option<u64> {
        self.details
            .as_ref()
            .and_then(|d| d.get("retry_after"))
            .and_then(serde_json::Value::as_u64)
    }
}

impl From<reqwest::Error> for MetadataError {
    fn from(err: reqwest::Error) -> Self {
        if err.is_timeout() {
            Self::timeout(format!("Request timed out: {err}"))
        } else if err.is_connect() {
            Self::connection_failed(format!("Connection failed: {err}"))
        } else if err.is_decode() {
            Self::parse_error(format!("Failed to decode response: {err}"))
        } else {
            Self::network(format!("Network error: {err}"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rate_limited_serializes_snake_case() {
        let err = MetadataError::rate_limited("rate limit", Some(42));
        let serialized = serde_json::to_string(&err.kind).unwrap();
        assert_eq!(serialized, "\"rate_limited\"");
        assert_eq!(err.retry_after(), Some(42));
    }

    #[test]
    fn from_response_status_maps_known_codes() {
        assert_eq!(
            MetadataError::from_response_status(404, None, None).kind,
            ErrorKind::NotFound
        );
        assert_eq!(
            MetadataError::from_response_status(429, Some(10), None).kind,
            ErrorKind::RateLimited
        );
        assert_eq!(
            MetadataError::from_response_status(401, None, None).kind,
            ErrorKind::AuthenticationFailed
        );
        assert_eq!(
            MetadataError::from_response_status(500, None, None).kind,
            ErrorKind::ApiError
        );
    }

    #[test]
    fn retry_after_round_trips() {
        let err = MetadataError::from_response_status(429, Some(7), None);
        assert_eq!(err.retry_after(), Some(7));
    }
}
