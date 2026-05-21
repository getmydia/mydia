//! Pick a globally consistent assignment across the classifier's
//! per-token candidate lists. Returns a [`ResolverResult`] that the
//! public `parse` function tops up with quality + confidence.
//!
//! Port of `lib/mydia/library/release_parser/resolver.ex`
//! (simplified — the Elixir version carries field-confidence and
//! engine-flags maps that this port currently elides; the resolver
//! still drives the four-way (title / year / season / episodes)
//! inference Phoenix's tests assert on).

use super::candidate::{Candidate, CandidateLabel, CandidateValue};
use super::title_assembler;
use super::tokenizer::{Anchors, Token};
use super::MediaKind;
use super::TargetContext;

#[derive(Debug, Clone, Default)]
pub struct ResolverResult {
    pub kind: MediaKind,
    pub title: Option<String>,
    pub year: Option<i32>,
    pub season: Option<i32>,
    pub episodes: Option<Vec<i32>>,
    pub release_group: Option<String>,
}

/// Resolve the classifier's candidate sets to a single assignment.
#[must_use]
pub fn resolve(
    _input: &str,
    tokens: &[Token],
    classified: &[Vec<Candidate>],
    _anchors: &Anchors,
    target: Option<&TargetContext>,
) -> ResolverResult {
    // 1. Year — highest-confidence Year candidate wins.
    let year = pick_best(classified, CandidateLabel::Year).and_then(|c| match c.value {
        Some(CandidateValue::YearValue(y)) => Some(y),
        _ => None,
    });

    // 2. Episode marker
    let episode_pick = pick_best(classified, CandidateLabel::EpisodeMarker);
    let (mut season_from_ep, mut episodes) = match episode_pick.and_then(|c| c.value.clone()) {
        Some(CandidateValue::EpisodeRef { season, episodes }) => (season, Some(episodes)),
        _ => (None, None),
    };

    // 3. Standalone season marker — only used when episode marker
    //    didn't carry a season.
    if season_from_ep.is_none() {
        if let Some(cand) = pick_best(classified, CandidateLabel::SeasonMarker) {
            if let Some(CandidateValue::SeasonRef(n)) = cand.value {
                season_from_ep = Some(n);
            }
        }
    }

    let season = season_from_ep;

    // 4. Title — assembled from the title-zone tokens, unless we
    //    have a target binding.
    let title_from_filename = title_assembler::assemble(tokens, classified);

    // 5. Type inference based on what we found.
    let kind = if episodes.as_ref().is_some_and(|v| !v.is_empty()) || season.is_some() {
        MediaKind::TvShow
    } else if year.is_some() {
        MediaKind::Movie
    } else {
        MediaKind::Unknown
    };

    // 6. Apply target binding when supplied.
    let (final_kind, final_title, final_year) = if let Some(t) = target {
        // Lock title/kind/year from the target.
        (t.kind, Some(t.title.clone()), t.year.or(year))
    } else {
        (kind, title_from_filename, year)
    };

    // Empty episodes vector -> None
    if let Some(v) = &episodes {
        if v.is_empty() {
            episodes = None;
        }
    }

    ResolverResult {
        kind: final_kind,
        title: final_title,
        year: final_year,
        season,
        episodes,
        release_group: None,
    }
}

fn pick_best(classified: &[Vec<Candidate>], label: CandidateLabel) -> Option<&Candidate> {
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
