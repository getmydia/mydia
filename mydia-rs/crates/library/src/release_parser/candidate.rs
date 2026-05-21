//! Classifier hypothesis carried per-token.
//!
//! The classifier emits zero or more [`Candidate`]s per token; the
//! resolver picks a globally consistent assignment.

use serde::{Deserialize, Serialize};

/// Labels the classifier can assign. Free-form-feeling but kept as
/// an enum so the resolver can pattern-match.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CandidateLabel {
    TitleCandidate,
    Year,
    Resolution,
    Source,
    Codec,
    Audio,
    Hdr,
    Language,
    StreamingService,
    ReleaseGroup,
    EpisodeMarker,
    SeasonMarker,
    Container,
    Proper,
    Repack,
}

/// Zone the token sits in — title (before all anchors) or metadata
/// (after).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Zone {
    Title,
    Metadata,
    Anywhere,
}

/// One hypothesis per token.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Candidate {
    /// Index into the token vector — keeps `Candidate` `Copy`-light
    /// and avoids the ownership dance an owning `Token` would force.
    pub token_index: usize,
    pub label: CandidateLabel,
    pub confidence: f64,
    pub zone: Zone,
    /// Optional structured value — used by episode markers to carry
    /// the parsed (season, [episodes]) tuple.
    pub value: Option<CandidateValue>,
}

/// Structured payload that doesn't fit in `value: String` shape.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum CandidateValue {
    /// (season, episodes). `season` is `None` for `Exx`-only markers.
    EpisodeRef {
        season: Option<i32>,
        episodes: Vec<i32>,
    },
    /// Standalone season marker (`S01`, `Season 1`).
    SeasonRef(i32),
    /// Year as i32.
    YearValue(i32),
    /// Plain string for resolution/source/codec/etc.
    StringValue(String),
}
