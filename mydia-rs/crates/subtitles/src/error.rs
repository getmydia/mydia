//! Subtitle error taxonomy.
//!
//! Mirrors the error atom set used in `lib/mydia/subtitles/`.
//! Serialized to `snake_case` for parity with the Phoenix wire shape.

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SubtitleErrorKind {
    /// Underlying provider isn't configured (missing URL / API key).
    NotConfigured,
    /// Provider rejected credentials.
    AuthenticationFailed,
    /// Hit a rate limit; caller should respect `retry_after`.
    RateLimited,
    /// Daily / monthly download quota exhausted.
    QuotaExceeded,
    /// Subtitle not found on the upstream service.
    NotFound,
    /// Provider returned an unrecoverable transient failure.
    ServiceUnavailable,
    /// HTTP error (4xx/5xx not covered by the more specific variants).
    HttpError,
    /// Network / transport error.
    Network,
    /// Provider responded with malformed payload.
    Parse,
    /// Caller passed invalid arguments (missing language code, etc.).
    InvalidRequest,
    /// Hash mismatch between requested + downloaded subtitle.
    HashMismatch,
    /// Unknown / unclassified.
    Unknown,
}

impl SubtitleErrorKind {
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::NotConfigured => "Not configured",
            Self::AuthenticationFailed => "Authentication failed",
            Self::RateLimited => "Rate limited",
            Self::QuotaExceeded => "Quota exceeded",
            Self::NotFound => "Not found",
            Self::ServiceUnavailable => "Service unavailable",
            Self::HttpError => "HTTP error",
            Self::Network => "Network error",
            Self::Parse => "Parse error",
            Self::InvalidRequest => "Invalid request",
            Self::HashMismatch => "Hash mismatch",
            Self::Unknown => "Unknown",
        }
    }
}

#[derive(Debug, Error, Clone)]
#[error("{}: {message}", kind.label())]
pub struct SubtitleError {
    pub kind: SubtitleErrorKind,
    pub message: String,
    pub details: Option<serde_json::Value>,
}

impl SubtitleError {
    #[must_use]
    pub fn new(
        kind: SubtitleErrorKind,
        message: impl Into<String>,
        details: Option<serde_json::Value>,
    ) -> Self {
        Self {
            kind,
            message: message.into(),
            details,
        }
    }

    pub fn not_configured(message: impl Into<String>) -> Self {
        Self::new(SubtitleErrorKind::NotConfigured, message, None)
    }

    pub fn authentication_failed(message: impl Into<String>) -> Self {
        Self::new(SubtitleErrorKind::AuthenticationFailed, message, None)
    }

    pub fn rate_limited(message: impl Into<String>, retry_after: Option<u64>) -> Self {
        let details = retry_after.map(|s| serde_json::json!({ "retry_after": s }));
        Self::new(SubtitleErrorKind::RateLimited, message, details)
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(SubtitleErrorKind::NotFound, message, None)
    }

    pub fn service_unavailable(message: impl Into<String>) -> Self {
        Self::new(SubtitleErrorKind::ServiceUnavailable, message, None)
    }

    pub fn http_error(message: impl Into<String>, status: u16) -> Self {
        Self::new(
            SubtitleErrorKind::HttpError,
            message,
            Some(serde_json::json!({ "status": status })),
        )
    }

    pub fn network(message: impl Into<String>) -> Self {
        Self::new(SubtitleErrorKind::Network, message, None)
    }

    pub fn parse(message: impl Into<String>) -> Self {
        Self::new(SubtitleErrorKind::Parse, message, None)
    }

    pub fn invalid_request(message: impl Into<String>) -> Self {
        Self::new(SubtitleErrorKind::InvalidRequest, message, None)
    }

    pub fn hash_mismatch(message: impl Into<String>) -> Self {
        Self::new(SubtitleErrorKind::HashMismatch, message, None)
    }

    pub fn unknown(message: impl Into<String>) -> Self {
        Self::new(SubtitleErrorKind::Unknown, message, None)
    }

    #[must_use]
    pub fn retry_after(&self) -> Option<u64> {
        self.details
            .as_ref()
            .and_then(|d| d.get("retry_after"))
            .and_then(serde_json::Value::as_u64)
    }
}

impl From<reqwest::Error> for SubtitleError {
    fn from(err: reqwest::Error) -> Self {
        if err.is_timeout() {
            Self::network(format!("timeout: {err}"))
        } else if err.is_connect() {
            Self::network(format!("connection failed: {err}"))
        } else if err.is_decode() {
            Self::parse(format!("decode failed: {err}"))
        } else {
            Self::network(format!("network: {err}"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kind_serializes_snake_case() {
        assert_eq!(
            serde_json::to_string(&SubtitleErrorKind::QuotaExceeded).unwrap(),
            "\"quota_exceeded\""
        );
        assert_eq!(
            serde_json::to_string(&SubtitleErrorKind::HashMismatch).unwrap(),
            "\"hash_mismatch\""
        );
    }

    #[test]
    fn rate_limited_round_trips_retry_after() {
        let err = SubtitleError::rate_limited("slow down", Some(60));
        assert_eq!(err.retry_after(), Some(60));
    }
}
