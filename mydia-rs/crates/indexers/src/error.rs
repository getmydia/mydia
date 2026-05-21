//! Error taxonomy for indexer operations.
//!
//! Port of `lib/mydia/indexers/adapter/error.ex`. Mirrors the Elixir
//! `error_type` atom union exactly, serialized to `snake_case` so wire
//! shapes line up during U34's parallel compatibility window.

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Variant discriminant for [`IndexerError`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    /// Unable to connect (refused, host unreachable).
    ConnectionFailed,
    /// Invalid credentials / 401 / 403.
    AuthenticationFailed,
    /// Request timed out.
    Timeout,
    /// HTTP 429 — caller should respect `retry_after`.
    RateLimited,
    /// Search query failed (no results / bad request).
    SearchFailed,
    /// Failed to parse response body / definition YAML / scraped HTML.
    ParseError,
    /// Caller config is malformed.
    InvalidConfig,
    /// Generic upstream 4xx/5xx error.
    ApiError,
    /// Network-layer error (DNS, TLS, transport).
    NetworkError,
    /// Resource not found (HTTP 404).
    NotFound,
    /// Unknown / unclassified.
    Unknown,
}

impl ErrorKind {
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::ConnectionFailed => "Connection failed",
            Self::AuthenticationFailed => "Authentication failed",
            Self::Timeout => "Timeout",
            Self::RateLimited => "Rate limited",
            Self::SearchFailed => "Search failed",
            Self::ParseError => "Parse error",
            Self::InvalidConfig => "Invalid config",
            Self::ApiError => "API error",
            Self::NetworkError => "Network error",
            Self::NotFound => "Not found",
            Self::Unknown => "Unknown",
        }
    }
}

/// Structured error returned by every adapter call.
#[derive(Debug, Error, Clone)]
#[error("{}: {message}", kind.label())]
pub struct IndexerError {
    pub kind: ErrorKind,
    pub message: String,
    pub details: Option<serde_json::Value>,
}

impl IndexerError {
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

    pub fn connection_failed(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::ConnectionFailed, message, None)
    }

    pub fn authentication_failed(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::AuthenticationFailed, message, None)
    }

    pub fn timeout(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Timeout, message, None)
    }

    pub fn rate_limited(message: impl Into<String>, retry_after: Option<u64>) -> Self {
        let details = retry_after.map(|s| serde_json::json!({ "retry_after": s, "status": 429 }));
        Self::new(ErrorKind::RateLimited, message, details)
    }

    pub fn search_failed(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::SearchFailed, message, None)
    }

    pub fn parse_error(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::ParseError, message, None)
    }

    pub fn invalid_config(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::InvalidConfig, message, None)
    }

    pub fn api_error(message: impl Into<String>, status: u16) -> Self {
        Self::new(
            ErrorKind::ApiError,
            message,
            Some(serde_json::json!({ "status": status })),
        )
    }

    pub fn network(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::NetworkError, message, None)
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::NotFound, message, None)
    }

    pub fn unknown(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Unknown, message, None)
    }

    /// Map a non-success HTTP status to the appropriate variant. Mirrors
    /// `Error.from_req_error/1` for `Req.Response`.
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
            ErrorKind::ApiError => format!("HTTP {status}"),
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

    #[must_use]
    pub fn retry_after(&self) -> Option<u64> {
        self.details
            .as_ref()
            .and_then(|d| d.get("retry_after"))
            .and_then(serde_json::Value::as_u64)
    }
}

impl From<reqwest::Error> for IndexerError {
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
    fn rate_limited_carries_retry_after() {
        let err = IndexerError::rate_limited("slow down", Some(42));
        assert_eq!(err.kind, ErrorKind::RateLimited);
        assert_eq!(err.retry_after(), Some(42));
    }

    #[test]
    fn from_response_status_maps_known_codes() {
        assert_eq!(
            IndexerError::from_response_status(404, None, None).kind,
            ErrorKind::NotFound
        );
        assert_eq!(
            IndexerError::from_response_status(429, Some(10), None).kind,
            ErrorKind::RateLimited
        );
        assert_eq!(
            IndexerError::from_response_status(401, None, None).kind,
            ErrorKind::AuthenticationFailed
        );
        assert_eq!(
            IndexerError::from_response_status(500, None, None).kind,
            ErrorKind::ApiError
        );
    }

    #[test]
    fn kind_serializes_snake_case() {
        let s = serde_json::to_string(&ErrorKind::RateLimited).unwrap();
        assert_eq!(s, "\"rate_limited\"");
        let s = serde_json::to_string(&ErrorKind::AuthenticationFailed).unwrap();
        assert_eq!(s, "\"authentication_failed\"");
    }
}
