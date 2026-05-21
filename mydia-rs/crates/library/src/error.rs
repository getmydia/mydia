//! Top-level error type for the library crate.
//!
//! Sub-modules carry their own narrower errors (e.g. `ParseError`
//! inside [`crate::release_parser`]); this enum is the surface seen
//! by U17 workers and U22+ admin `LiveViews` when they call into
//! the crate's public API.

use std::io;

use thiserror::Error;

/// Errors emitted by library scanning, file analysis, and enrichment.
#[derive(Debug, Error)]
pub enum LibraryError {
    /// I/O error while traversing the file system or reading file
    /// metadata. Phoenix `:eacces`, `:enoent`, `:enotdir`, etc.
    #[error("io error at {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: io::Error,
    },

    /// `ffprobe` could not be located on `PATH`. Phoenix logs and
    /// surfaces the same case via `:ffprobe_not_found`.
    #[error("ffprobe binary not found on PATH")]
    FfprobeNotFound,

    /// `ffprobe` exited with a non-zero status. The string body is
    /// the trimmed stderr (or stdout, since the Elixir port mirrored
    /// both into one stream).
    #[error("ffprobe failed: {0}")]
    FfprobeFailed(String),

    /// `ffprobe` produced output but it could not be parsed. The
    /// embedded `serde_json` error carries the offset.
    #[error("ffprobe produced invalid JSON: {0}")]
    FfprobeOutputInvalid(#[from] serde_json::Error),

    /// `ffprobe` exceeded the configured timeout (default 30s).
    /// Mirrors the Phoenix `:timeout` shape from the fast-library-
    /// import work.
    #[error("ffprobe timed out after {seconds}s")]
    FfprobeTimeout { seconds: u64 },

    /// Provider-side metadata fetch failed during enrichment.
    #[error("metadata provider error: {0}")]
    Metadata(#[from] mydia_rs_metadata::MetadataError),

    /// The scan target is not a directory.
    #[error("not a directory: {0}")]
    NotADirectory(String),

    /// The scan target does not exist.
    #[error("path not found: {0}")]
    NotFound(String),

    /// Permission denied opening the scan target.
    #[error("permission denied: {0}")]
    PermissionDenied(String),
}
