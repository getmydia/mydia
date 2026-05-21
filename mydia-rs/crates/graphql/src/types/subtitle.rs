//! `:subtitle_track` + `:subtitle_format` enum — port of
//! `common_types.ex:305-339` and `enum_types.ex:49-58`.
//!
//! Real per-file subtitle listing lands with U21 (subtitles). U14 ships
//! the shape so the schema contract is stable.

use async_graphql::{Enum, SimpleObject};

#[derive(Debug, Copy, Clone, PartialEq, Eq, Enum, Default)]
#[graphql(name = "SubtitleFormat")]
pub enum SubtitleFormat {
    Srt,
    #[default]
    Vtt,
    Ass,
    Ssa,
    Pgs,
    Vobsub,
    Unknown,
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "SubtitleTrack")]
pub struct SubtitleTrack {
    pub track_id: String,
    pub language: String,
    pub title: String,
    pub format: String,
    pub embedded: bool,
    /// URL is computed by `SubtitleResolver.url/3` on the Phoenix side;
    /// the Rust port computes it inline (`/api/player/v1/subtitles/...`).
    /// Lands as a real field when U21 wires the extractor.
    pub url: Option<String>,
}
