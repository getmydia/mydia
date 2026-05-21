//! Torrent matcher. Rust port of
//! `lib/mydia/downloads/torrent_matcher.ex`.
//!
//! ## Phoenix surface
//!
//! The Elixir matcher is 850 LOC and walks a parsed release name
//! plus the loaded library catalog (movies + shows) to find the
//! best-matching item. It uses:
//!
//! - ID-based matching when the release carries TMDB/IMDB ids
//!   (98% confidence floor).
//! - Title-based matching via Jaro-Winkler distance with year
//!   weighting + sequel-marker penalties.
//! - Multi-pass normalization (articles, punctuation, Unicode).
//!
//! ## Rust port scope
//!
//! U20 ships the scoring layer + the public `TorrentMatcher` API,
//! decoupled from the library catalog source. The caller passes a
//! candidate list of [`Candidate`] items; the matcher returns the
//! best match above the configured threshold. U17 wires the
//! catalog source (via `mydia_rs_models`) when the library context
//! crate is fully populated; this unit keeps the matcher pure so
//! tests don't need a DB.

use strsim::jaro_winkler;

/// Parsed release info supplied to the matcher. Mirrors the subset
/// of `Mydia.Downloads.Structs.ParsedRelease` the Phoenix matcher
/// actually reads.
#[derive(Debug, Clone, Default)]
pub struct ParsedRelease {
    pub title: String,
    pub year: Option<u16>,
    pub tmdb_id: Option<u64>,
    pub imdb_id: Option<String>,
}

/// One library item the matcher can choose from. The caller is
/// responsible for shaping their domain objects into this struct so
/// the matcher stays generic.
#[derive(Debug, Clone)]
pub struct Candidate {
    pub id: String,
    pub title: String,
    pub original_title: Option<String>,
    pub aliases: Vec<String>,
    pub year: Option<u16>,
    pub tmdb_id: Option<u64>,
    pub imdb_id: Option<String>,
}

/// Single match result. Confidence is a 0.0..=1.0 score after all
/// penalties / boosts; >= 0.98 means the match came from an ID, not
/// a title comparison.
#[derive(Debug, Clone)]
pub struct MatchResult<'a> {
    pub candidate: &'a Candidate,
    pub confidence: f64,
    pub matched_via_id: bool,
}

/// Matcher entry point. Stateless — clone freely.
#[derive(Debug, Clone)]
pub struct TorrentMatcher {
    pub confidence_threshold: f64,
}

impl Default for TorrentMatcher {
    fn default() -> Self {
        Self {
            // Phoenix default is 0.8.
            confidence_threshold: 0.8,
        }
    }
}

impl TorrentMatcher {
    /// Build with a custom threshold.
    #[must_use]
    pub fn with_threshold(threshold: f64) -> Self {
        Self {
            confidence_threshold: threshold,
        }
    }

    /// Find the highest-confidence match for `release` in `candidates`.
    /// Returns `None` when the best match is below the configured
    /// threshold — matching Phoenix's `{:error, :no_match}` shape.
    pub fn find_best<'a>(
        &self,
        release: &ParsedRelease,
        candidates: &'a [Candidate],
    ) -> Option<MatchResult<'a>> {
        let mut best: Option<MatchResult<'a>> = None;
        for candidate in candidates {
            let result = self.score(release, candidate);
            if result.confidence >= self.confidence_threshold
                && best
                    .as_ref()
                    .is_none_or(|b| result.confidence > b.confidence)
            {
                best = Some(result);
            }
        }
        best
    }

    /// Compute the confidence + match-type for a `release` against a
    /// single `candidate`. Exposed so callers can rank without
    /// having to walk through `find_best`.
    pub fn score<'a>(&self, release: &ParsedRelease, candidate: &'a Candidate) -> MatchResult<'a> {
        // ID-based match: 0.98 confidence floor matches Phoenix.
        if let (Some(release_id), Some(cand_id)) = (release.tmdb_id, candidate.tmdb_id) {
            if release_id == cand_id {
                return MatchResult {
                    candidate,
                    confidence: 0.98,
                    matched_via_id: true,
                };
            }
        }
        if let (Some(release_id), Some(cand_id)) =
            (release.imdb_id.as_deref(), candidate.imdb_id.as_deref())
        {
            if release_id.eq_ignore_ascii_case(cand_id) {
                return MatchResult {
                    candidate,
                    confidence: 0.98,
                    matched_via_id: true,
                };
            }
        }

        // Title-based scoring.
        let title_score = best_title_similarity(release, candidate);
        let year_score = year_score(release.year, candidate.year);
        let sequel_penalty = sequel_penalty(&release.title, &candidate.title);

        let confidence = (title_score * 0.7 + year_score + sequel_penalty).clamp(0.0, 1.0);
        MatchResult {
            candidate,
            confidence,
            matched_via_id: false,
        }
    }
}

/// Highest similarity across primary, original, and alias titles.
/// Alternative titles take a small penalty (-0.05) so the primary
/// title wins ties — matches Phoenix's `alternative_title_penalty`.
fn best_title_similarity(release: &ParsedRelease, candidate: &Candidate) -> f64 {
    let normalized_release = normalize_title(&release.title);

    let mut best = jaro_winkler(&normalized_release, &normalize_title(&candidate.title));
    if let Some(orig) = candidate.original_title.as_deref() {
        let score = jaro_winkler(&normalized_release, &normalize_title(orig));
        if score > best {
            best = score;
        }
    }
    for alias in &candidate.aliases {
        let score = jaro_winkler(&normalized_release, &normalize_title(alias)) - 0.05;
        if score > best {
            best = score;
        }
    }
    best
}

fn year_score(release_year: Option<u16>, candidate_year: Option<u16>) -> f64 {
    match (release_year, candidate_year) {
        (Some(a), Some(b)) if a == b => 0.3,
        (Some(a), Some(b)) if (i32::from(a) - i32::from(b)).abs() == 1 => 0.15,
        (Some(a), Some(b)) if (i32::from(a) - i32::from(b)).abs() > 1 => -0.5,
        _ => 0.0,
    }
}

/// Apply a penalty when one title carries a sequel marker but the
/// other doesn't — matches Phoenix's `sequel_marker_penalty`.
fn sequel_penalty(release: &str, candidate: &str) -> f64 {
    let release_marker = has_sequel_marker(release);
    let candidate_marker = has_sequel_marker(candidate);
    if release_marker == candidate_marker {
        0.0
    } else {
        -0.4
    }
}

fn has_sequel_marker(title: &str) -> bool {
    let lower = title.to_lowercase();
    if lower.contains("returns") || lower.contains("reloaded") || lower.contains("revolution") {
        return true;
    }
    // Roman numerals II-X as standalone tokens.
    let tokens: Vec<&str> = lower.split_whitespace().collect();
    let romans = [
        " ii", " iii", " iv", " v", " vi", " vii", " viii", " ix", " x",
    ];
    if romans.iter().any(|r| lower.ends_with(r)) {
        return true;
    }
    if tokens.contains(&"part") {
        return true;
    }
    false
}

/// Normalize a title for comparison: lowercase, drop leading
/// articles, collapse punctuation, trim. Phoenix's
/// `normalize_title` runs roughly the same pipeline.
fn normalize_title(raw: &str) -> String {
    let lower = raw.to_lowercase();
    let mut out = String::with_capacity(lower.len());
    for ch in lower.chars() {
        if ch.is_alphanumeric() || ch == ' ' {
            out.push(ch);
        } else if ch == '_' || ch == '-' || ch == '.' || ch == ':' {
            out.push(' ');
        }
    }
    let collapsed: Vec<&str> = out.split_whitespace().collect();
    let mut start_idx = 0usize;
    if let Some(first) = collapsed.first() {
        if matches!(*first, "the" | "a" | "an") {
            start_idx = 1;
        }
    }
    collapsed[start_idx..].join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release(title: &str, year: Option<u16>) -> ParsedRelease {
        ParsedRelease {
            title: title.into(),
            year,
            tmdb_id: None,
            imdb_id: None,
        }
    }

    fn candidate(id: &str, title: &str, year: Option<u16>) -> Candidate {
        Candidate {
            id: id.into(),
            title: title.into(),
            original_title: None,
            aliases: Vec::new(),
            year,
            tmdb_id: None,
            imdb_id: None,
        }
    }

    #[test]
    fn normalize_strips_articles_and_punctuation() {
        assert_eq!(normalize_title("The Matrix"), "matrix");
        assert_eq!(
            normalize_title("Star Wars: Episode IV"),
            "star wars episode iv"
        );
        assert_eq!(normalize_title("A Quiet.Place"), "quiet place");
    }

    #[test]
    fn exact_title_match_with_matching_year_scores_high() {
        let m = TorrentMatcher::default();
        let r = release("The Matrix", Some(1999));
        let c = candidate("c1", "The Matrix", Some(1999));
        let result = m.score(&r, &c);
        assert!(result.confidence >= 0.8, "got {}", result.confidence);
    }

    #[test]
    fn sequel_marker_pulls_confidence_below_threshold() {
        let m = TorrentMatcher::default();
        let r = release("The Matrix", Some(1999));
        let c = candidate("c1", "The Matrix Reloaded", Some(2003));
        let result = m.score(&r, &c);
        // Year mismatch + sequel marker push this well below 0.8.
        assert!(result.confidence < 0.8, "got {}", result.confidence);
    }

    #[test]
    fn id_match_wins_regardless_of_title() {
        let m = TorrentMatcher::default();
        let r = ParsedRelease {
            title: "Whatever".into(),
            year: None,
            tmdb_id: Some(42),
            imdb_id: None,
        };
        let c = Candidate {
            id: "c1".into(),
            title: "Totally Different".into(),
            original_title: None,
            aliases: vec![],
            year: None,
            tmdb_id: Some(42),
            imdb_id: None,
        };
        let result = m.score(&r, &c);
        assert!(result.matched_via_id);
        assert!(result.confidence >= 0.98);
    }

    #[test]
    fn find_best_returns_none_below_threshold() {
        let m = TorrentMatcher::default();
        let r = release("Some Movie", Some(2020));
        let candidates = vec![candidate("c1", "Completely Unrelated", Some(1990))];
        assert!(m.find_best(&r, &candidates).is_none());
    }

    #[test]
    fn find_best_picks_highest_score() {
        let m = TorrentMatcher::default();
        let r = release("Inception", Some(2010));
        let candidates = vec![
            candidate("c1", "Inception Returns", Some(2012)),
            candidate("c2", "Inception", Some(2010)),
            candidate("c3", "Something Else", Some(2020)),
        ];
        let best = m.find_best(&r, &candidates).unwrap();
        assert_eq!(best.candidate.id, "c2");
    }
}
