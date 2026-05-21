//! Walk the classified tokens and gather quality fields into a
//! [`crate::release_parser::Quality`] struct.
//!
//! Port of `lib/mydia/library/release_parser/quality_extractor.ex`
//! (simplified — the Elixir version supports a `:standardize` opt
//! that returns canonical values like `"H.264/AVC"` and
//! `"Dolby Digital Plus 5.1"`. The current Rust port returns raw
//! token values to match the `standardize: false` default, plus
//! canonical casing for sources via the vocabulary helpers — exactly
//! what the canonical Phoenix tests assert).

use super::candidate::{Candidate, CandidateLabel, CandidateValue};
use super::tokenizer::Token;
use super::vocabulary;
use super::Quality;

/// Extract quality from the tokens + classifier output.
#[must_use]
pub fn extract(_tokens: &[Token], classified: &[Vec<Candidate>]) -> Quality {
    let mut quality = Quality::default();

    if let Some(c) = highest(classified, CandidateLabel::Resolution) {
        quality.resolution = string_value(c);
    }

    if let Some(c) = highest(classified, CandidateLabel::Source) {
        if let Some(s) = string_value(c) {
            // Preserve the canonical casing from the vocabulary where
            // possible — Phoenix's tests assert `BluRay`, not
            // `bluray`.
            quality.source =
                Some(vocabulary::canonical_source(&s).map_or_else(|| s.clone(), str::to_owned));
        }
    }

    if let Some(c) = highest(classified, CandidateLabel::Codec) {
        quality.codec = string_value(c);
    }

    if let Some(c) = highest(classified, CandidateLabel::Hdr) {
        quality.hdr_format = string_value(c);
    }

    if let Some(c) = highest(classified, CandidateLabel::Audio) {
        quality.audio = string_value(c);
    }

    quality
}

fn highest(classified: &[Vec<Candidate>], label: CandidateLabel) -> Option<&Candidate> {
    classified
        .iter()
        .flat_map(|v| v.iter())
        .filter(|c| c.label == label)
        .max_by(|a, b| {
            a.confidence
                .partial_cmp(&b.confidence)
                .unwrap_or(std::cmp::Ordering::Equal)
        })
}

fn string_value(c: &Candidate) -> Option<String> {
    match &c.value {
        Some(CandidateValue::StringValue(s)) => Some(s.clone()),
        _ => None,
    }
}
