//! Streaming GraphQL types — port of
//! `lib/mydia_web/schema/common_types.ex:274-304` and
//! `:streaming_session_result`. The enum mirror lives in
//! `lib/mydia_web/schema/enum_types.ex:60-72`.
//!
//! [`StreamingStrategy`] is the input enum the player uses to request
//! a session (`hls_copy` or `transcode`). [`StreamingCandidateStrategy`]
//! is the wider response enum that includes `direct_play` and `remux`
//! options — Phoenix uses one enum for input and another for output to
//! disallow the player passing `direct_play` to the start-session
//! mutation.

use async_graphql::{Enum, SimpleObject, ID};

/// Input enum for `startStreamingSession.strategy`. The Phoenix
/// `:streaming_strategy` GraphQL enum maps `:hls_copy` → "HLS_COPY"
/// and `:transcode` → "TRANSCODE" by default. async-graphql's enum
/// rendering matches when we annotate with `rename_items = "SCREAMING_SNAKE_CASE"`
/// (the default for Rust enums in async-graphql).
#[derive(Debug, Copy, Clone, PartialEq, Eq, Enum)]
#[graphql(name = "StreamingStrategy")]
pub enum StreamingStrategy {
    HlsCopy,
    Transcode,
}

impl StreamingStrategy {
    /// String form Phoenix's `HlsSession` uses internally (`:copy` or
    /// `:transcode`). Surfaced here so the resolver can pass it
    /// through unchanged when it's stubbed against U19.
    pub fn as_session_mode(self) -> &'static str {
        match self {
            Self::HlsCopy => "copy",
            Self::Transcode => "transcode",
        }
    }
}

/// Wider response enum for `StreamingCandidate.strategy`. Includes
/// the direct-play and remux options the resolver may return.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Enum)]
#[graphql(name = "StreamingCandidateStrategy")]
pub enum StreamingCandidateStrategy {
    DirectPlay,
    Remux,
    HlsCopy,
    Transcode,
}

impl StreamingCandidateStrategy {
    /// Parse Phoenix's internal string representation
    /// ("DIRECT_PLAY", "REMUX", "HLS_COPY", "TRANSCODE") into the
    /// enum. Returns `None` for unrecognized strings.
    pub fn from_phoenix_str(value: &str) -> Option<Self> {
        match value {
            "DIRECT_PLAY" => Some(Self::DirectPlay),
            "REMUX" => Some(Self::Remux),
            "HLS_COPY" => Some(Self::HlsCopy),
            "TRANSCODE" => Some(Self::Transcode),
            _ => None,
        }
    }
}

/// One playback strategy the server can serve for a given file.
#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "StreamingCandidate")]
pub struct StreamingCandidate {
    pub strategy: StreamingCandidateStrategy,
    pub mime: String,
    pub container: String,
    pub video_codec: Option<String>,
    pub audio_codec: Option<String>,
}

/// Source-file metadata returned alongside the candidate list.
#[derive(Debug, Clone, SimpleObject, Default)]
#[graphql(name = "StreamingMetadata")]
pub struct StreamingMetadata {
    pub duration: Option<f64>,
    pub width: Option<i32>,
    pub height: Option<i32>,
    pub bitrate: Option<i64>,
    pub resolution: Option<String>,
    pub hdr_format: Option<String>,
    pub original_codec: Option<String>,
    pub original_audio_codec: Option<String>,
    pub container: Option<String>,
}

/// Response shape for the `streamingCandidates` query.
#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "StreamingCandidatesResult")]
pub struct StreamingCandidatesResult {
    pub file_id: ID,
    pub candidates: Vec<StreamingCandidate>,
    pub metadata: StreamingMetadata,
}

/// Response shape for `startStreamingSession`. Per the MEMORY note:
/// returns `session_id + duration` only — NOT a wrapped HLS URL.
#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "StreamingSessionResult")]
pub struct StreamingSessionResult {
    pub session_id: String,
    pub duration: Option<f64>,
}
