//! Error taxonomy shared by every download-client adapter. Mirrors
//! Phoenix's `Mydia.Downloads.Client.Error` shape so call sites can
//! pattern-match on the same categories.

use std::path::PathBuf;

/// Single error type returned by every adapter method. Carries enough
/// context (status code, body excerpt) to let the caller decide
/// whether to retry, surface to the operator, or mark the download
/// as permanently failed.
#[derive(Debug, thiserror::Error)]
pub enum DownloadError {
    /// Adapter is misconfigured (missing host, missing API key, ...).
    /// User-recoverable by fixing the client row.
    #[error("invalid configuration: {0}")]
    InvalidConfig(String),

    /// Authentication against the remote client failed (401 / 403 /
    /// invalid API key).
    #[error("authentication failed: {0}")]
    AuthenticationFailed(String),

    /// HTTP transport failure (DNS, TCP, TLS, timeout).
    #[error("network error: {0}")]
    Network(String),

    /// Remote client returned an unexpected response (5xx, malformed
    /// JSON, missing field).
    #[error("api error: {message} (status: {status:?})")]
    Api {
        message: String,
        status: Option<u16>,
    },

    /// Requested resource (torrent / nzb id) is not present on the
    /// remote client.
    #[error("not found: {0}")]
    NotFound(String),

    /// The submitted torrent / NZB payload is malformed or rejected
    /// by the remote.
    #[error("invalid torrent payload: {0}")]
    InvalidTorrent(String),

    /// Local filesystem operation failed (used by blackhole, transcoder).
    #[error("filesystem error at {path}: {source}")]
    Fs {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    /// `FFmpeg` binary not present on `PATH`.
    #[error("ffmpeg binary not found")]
    FfmpegNotFound,

    /// `FFmpeg` exited with a non-zero status. Captures the tail of
    /// stderr so the operator can diagnose without re-running.
    #[error("ffmpeg failed with status {status}: {stderr}")]
    FfmpegFailed { status: i32, stderr: String },

    /// Caller-driven cancellation (job cancel, supervisor shutdown).
    #[error("job cancelled")]
    Cancelled,

    /// Catch-all for adapter-internal invariants that shouldn't be
    /// reachable in steady state. Use sparingly.
    #[error("internal error: {0}")]
    Internal(String),
}

impl DownloadError {
    /// Convenience constructor that mirrors Phoenix's `Error.api_error/1`.
    pub fn api(message: impl Into<String>) -> Self {
        Self::Api {
            message: message.into(),
            status: None,
        }
    }

    /// Variant of [`Self::api`] that also captures the HTTP status.
    pub fn api_with_status(message: impl Into<String>, status: u16) -> Self {
        Self::Api {
            message: message.into(),
            status: Some(status),
        }
    }

    /// Build a filesystem error from a path + IO error pair.
    pub fn fs(path: impl Into<PathBuf>, source: std::io::Error) -> Self {
        Self::Fs {
            path: path.into(),
            source,
        }
    }
}

impl From<reqwest::Error> for DownloadError {
    fn from(err: reqwest::Error) -> Self {
        // Both timeout and connect failures collapse to the same
        // surface — we keep the branch comment-shape for grep-ability
        // against Phoenix's `connection_failed | timeout` mapping
        // even though the value is currently identical.
        Self::Network(err.to_string())
    }
}

impl From<serde_json::Error> for DownloadError {
    fn from(err: serde_json::Error) -> Self {
        Self::api(format!("response parse error: {err}"))
    }
}
