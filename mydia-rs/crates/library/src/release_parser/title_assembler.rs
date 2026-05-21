//! Stitch the title-zone tokens back into a human-readable title.
//!
//! Phoenix runs a small heuristic — dots and underscores in the
//! original input become spaces, leading articles are preserved, and
//! a trailing season-word (`Season`) drops out. The port mirrors the
//! "join with single space" core behaviour. Edge cases (e.g.
//! parenthesized AKAs) are deferred.

use super::candidate::{Candidate, CandidateLabel, Zone};
use super::tokenizer::Token;

/// Assemble a title from the tokens in the title zone, given the
/// classifier output. Tokens whose strongest candidate is anything
/// other than `TitleCandidate` are excluded.
#[must_use]
pub fn assemble(tokens: &[Token], classified: &[Vec<Candidate>]) -> Option<String> {
    let mut parts = Vec::new();
    for (idx, token) in tokens.iter().enumerate() {
        let candidates = classified.get(idx).map_or(&[][..], Vec::as_slice);
        let strongest = candidates.iter().max_by(|a, b| {
            a.confidence
                .partial_cmp(&b.confidence)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        let include = matches!(
            strongest,
            Some(c) if c.zone == Zone::Title && c.label == CandidateLabel::TitleCandidate
        );
        if include {
            parts.push(token.value.as_str());
        }
    }

    if parts.is_empty() {
        None
    } else {
        Some(parts.join(" "))
    }
}
