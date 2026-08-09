//! Playback candidates, codec compatibility and byte production.
//!
//! Knows nothing about GraphQL or HTTP. Callers hand it facts and it hands
//! back decisions and bytes.

pub mod codec_string;
pub mod compatibility;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum StreamingError {
    #[error("ffmpeg could not be started for {path}: {detail}")]
    FfmpegStart { path: String, detail: String },

    #[error("ffmpeg failed for {path}: {detail}")]
    Ffmpeg { path: String, detail: String },

    #[error("{path} is not on disk")]
    Missing { path: String },
}
