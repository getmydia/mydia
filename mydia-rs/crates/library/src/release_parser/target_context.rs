//! Optional binding context for a parse — the caller has already
//! decided which media item this file belongs to and wants the
//! parser to lock title/year/kind to those values.
//!
//! Rust port of `Mydia.Library.ReleaseParser.TargetContext`. The
//! Phoenix module also exposes `from_media_item/1`; that helper is
//! intentionally deferred to U17 so this crate stays free of the
//! `mydia_rs_models::MediaItem` association assumptions.

use crate::release_parser::MediaKind;

/// Hints supplied alongside a parse so the parser can lock fields
/// instead of inferring them.
#[derive(Debug, Clone)]
pub struct TargetContext {
    pub kind: MediaKind,
    pub title: String,
    pub year: Option<i32>,
    pub alt_titles: Vec<String>,
    /// Seasons known to exist for this media item. The resolver uses
    /// this to flag `season_out_of_range` when the parsed season
    /// doesn't appear in the list.
    pub known_seasons: Vec<i32>,
}

impl TargetContext {
    /// Build a minimal context with no alt titles or known seasons.
    #[must_use]
    pub fn new(kind: MediaKind, title: impl Into<String>) -> Self {
        Self {
            kind,
            title: title.into(),
            year: None,
            alt_titles: Vec::new(),
            known_seasons: Vec::new(),
        }
    }
}
