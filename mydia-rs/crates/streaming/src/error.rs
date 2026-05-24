//! Streaming-side error taxonomy.
//!
//! Mirrors the rescue points in Phoenix's `Mydia.Streaming.HlsSession` /
//! `FfmpegHlsTranscoder` modules. Each variant is shape-stable so the
//! GraphQL `playback` resolver in U11 can match on it.

use std::io;
use std::path::PathBuf;

use thiserror::Error;

/// Top-level error returned by every public function in this crate.
#[derive(Debug, Error)]
pub enum StreamingError {
    /// The on-disk session directory could not be created or removed.
    #[error("filesystem error at {path}: {source}")]
    Filesystem {
        path: PathBuf,
        #[source]
        source: io::Error,
    },

    /// The `ffmpeg` binary was not found on `$PATH`. Surfaced verbatim
    /// to the player so the operator can install / configure it.
    #[error("ffmpeg binary not found on PATH")]
    FfmpegNotFound,

    /// `ffmpeg` exited with a non-zero status. The captured stderr is
    /// truncated to a few KiB to keep the error payload small.
    #[error("ffmpeg exited with status {status}: {stderr}")]
    FfmpegFailed { status: i32, stderr: String },

    /// `ffmpeg` did not produce its expected first playlist within the
    /// configured timeout. Most often points at a slow container probe
    /// or a stuck input.
    #[error("ffmpeg did not become ready within {seconds}s")]
    FfmpegReadyTimeout { seconds: u64 },

    /// The transcode / remux task was cancelled (idle timeout, explicit
    /// stop, or supervisor shutdown). Carries the human-readable
    /// reason for logs.
    #[error("session cancelled: {reason}")]
    Cancelled { reason: String },

    /// An apalis-style retryable I/O error launching the `ffmpeg`
    /// child. Wraps the underlying `io::Error`.
    #[error("could not spawn ffmpeg: {0}")]
    Spawn(#[source] io::Error),

    /// The configured input path does not point at a file readable by
    /// the running backend.
    #[error("input path is not readable: {path}")]
    InputNotReadable { path: PathBuf },
}

impl StreamingError {
    /// Helper used by call sites that want to attach a path to a raw
    /// `io::Error`.
    pub fn fs(path: impl Into<PathBuf>, source: io::Error) -> Self {
        Self::Filesystem {
            path: path.into(),
            source,
        }
    }

    /// True if the error reflects a transient infrastructure problem
    /// (apalis would retry these). Used by the supervisor when
    /// deciding whether to surface a `session_failed` event.
    pub fn is_transient(&self) -> bool {
        matches!(self, Self::Spawn(_) | Self::Filesystem { .. })
    }
}
