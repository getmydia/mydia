//! Filtering + ranking pipeline used by manual and automatic searches.
//!
//! Faithful port of `lib/mydia/indexers/release_ranker.ex`. The U17
//! workers (`MovieSearch`, `TvShowSearch`) consume this — the algorithm
//! must produce identical rankings during the parallel window.

use chrono::{DateTime, Duration, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;
use unicode_normalization::UnicodeNormalization;

use crate::search_result::{DownloadProtocol, RankedResult, ScoreBreakdown, SearchResult};
use crate::search_scorer::{score_result_with_breakdown, MediaType, QualityProfile, ScoreOpts};

const DEFAULT_MIN_SEEDERS: u32 = 0;
const TITLE_MATCH_THRESHOLD: f64 = 0.7;

/// Options for [`rank_all`] / [`select_best_result`] / [`filter_acceptable`].
#[derive(Debug, Clone, Default)]
pub struct RankingOptions {
    pub min_seeders: Option<u32>,
    pub min_ratio: Option<f64>,
    /// `(min_mb, max_mb)`; either side can be `None`.
    pub size_range: Option<(Option<u64>, Option<u64>)>,
    pub preferred_qualities: Option<Vec<String>>,
    pub preferred_tags: Vec<String>,
    pub blocked_tags: Vec<String>,
    pub search_query: Option<String>,
    pub quality_profile: Option<QualityProfile>,
    pub media_type: Option<MediaType>,
    pub expected_title: Option<String>,
    pub min_post_age_minutes: Option<u32>,
    pub now: Option<DateTime<Utc>>,
}

/// Best result by score, or `None` if no result passes filtering.
#[must_use]
pub fn select_best_result(
    results: Vec<SearchResult>,
    opts: &RankingOptions,
) -> Option<RankedResult> {
    rank_all(results, opts).into_iter().next()
}

/// Full ranked list, ordered by `(quality_preference_index, -score)`.
#[must_use]
pub fn rank_all(results: Vec<SearchResult>, opts: &RankingOptions) -> Vec<RankedResult> {
    let media_type = opts.media_type;
    let expected_title = opts.expected_title.as_deref();
    let search_query = opts.search_query.as_deref();

    let filtered = filter_acceptable(results, opts);
    let filtered = reject_tv_releases_for_movies(filtered, media_type);
    let filtered = reject_title_mismatches(filtered, expected_title);

    let mut ranked: Vec<RankedResult> = filtered
        .into_iter()
        .map(|r| {
            let breakdown = calculate_score_breakdown(&r, opts);
            RankedResult {
                result: r,
                score: breakdown.total,
                breakdown,
            }
        })
        .collect();

    ranked = reject_zero_title_match(ranked, search_query);
    sort_by_score_and_preferences(&mut ranked, opts.preferred_qualities.as_deref());
    ranked
}

/// Apply only the filtering layer — useful in admin/debug surfaces that
/// want the unscored result set.
#[must_use]
pub fn filter_acceptable(results: Vec<SearchResult>, opts: &RankingOptions) -> Vec<SearchResult> {
    let min_seeders = opts.min_seeders.unwrap_or(DEFAULT_MIN_SEEDERS);
    let min_ratio = opts.min_ratio;
    let size_range = opts.size_range;
    let blocked = &opts.blocked_tags;
    let min_post_age_minutes = opts.min_post_age_minutes;
    let now = opts.now.unwrap_or_else(Utc::now);

    results
        .into_iter()
        .filter(|r| {
            if !meets_seeder_minimum(r, min_seeders) {
                return false;
            }
            if let Some(ratio) = min_ratio {
                if !meets_ratio_minimum(r, ratio) {
                    return false;
                }
            }
            if let Some(range) = size_range {
                if !within_size_range(r, range) {
                    return false;
                }
            }
            if !not_blocked(r, blocked) {
                return false;
            }
            if !meets_post_age_minimum(r, min_post_age_minutes, now) {
                return false;
            }
            true
        })
        .collect()
}

fn meets_seeder_minimum(r: &SearchResult, min: u32) -> bool {
    match r.seeders {
        None => true,
        Some(s) => s >= min,
    }
}

fn meets_ratio_minimum(r: &SearchResult, min_ratio: f64) -> bool {
    match r.seeders {
        None => true,
        Some(s) => {
            let l = r.leechers.unwrap_or(0);
            let total = s + l;
            if total == 0 {
                return true;
            }
            f64::from(s) / f64::from(total) >= min_ratio
        }
    }
}

fn within_size_range(r: &SearchResult, range: (Option<u64>, Option<u64>)) -> bool {
    let size_mb = bytes_to_mb(r.size);
    let above_min = match range.0 {
        Some(m) => size_mb >= m as f64,
        None => true,
    };
    let below_max = match range.1 {
        Some(m) => size_mb <= m as f64,
        None => true,
    };
    above_min && below_max
}

fn not_blocked(r: &SearchResult, blocked_tags: &[String]) -> bool {
    if blocked_tags.is_empty() {
        return true;
    }
    let lower = r.title.to_lowercase();
    !blocked_tags
        .iter()
        .any(|tag| lower.contains(&tag.to_lowercase()))
}

fn meets_post_age_minimum(r: &SearchResult, min_minutes: Option<u32>, now: DateTime<Utc>) -> bool {
    let Some(minutes) = min_minutes else {
        return true;
    };
    if minutes == 0 {
        return true;
    }
    // Only applies to NZB releases with a usenet_date set.
    if r.download_protocol != Some(DownloadProtocol::Nzb) {
        return true;
    }
    let Some(posted) = r.usenet_date else {
        return true;
    };
    let cutoff = now - Duration::seconds(i64::from(minutes) * 60);
    posted <= cutoff
}

fn reject_tv_releases_for_movies(
    results: Vec<SearchResult>,
    media_type: Option<MediaType>,
) -> Vec<SearchResult> {
    if media_type != Some(MediaType::Movie) {
        return results;
    }
    let re = tv_season_regex();
    results
        .into_iter()
        .filter(|r| !re.is_match(&r.title))
        .collect()
}

fn reject_title_mismatches(
    results: Vec<SearchResult>,
    expected_title: Option<&str>,
) -> Vec<SearchResult> {
    let Some(expected) = expected_title else {
        return results;
    };
    let trimmed = expected.trim();
    if trimmed.is_empty() {
        return results;
    }
    let normalized_expected = normalize_for_comparison(trimmed);
    results
        .into_iter()
        .filter(|r| {
            matches!(
                parse_and_compare(&r.title, &normalized_expected),
                CompareOutcome::Match
            )
        })
        .collect()
}

enum CompareOutcome {
    Match,
    Mismatch,
}

fn parse_and_compare(title: &str, normalized_expected: &str) -> CompareOutcome {
    // The Phoenix side calls `TorrentParser.parse(result.title)` which
    // attempts to extract a clean show/movie title. For the Rust port
    // we apply the same normalization to the raw title — the U18+ work
    // that brings the TorrentParser port over can refine this.
    let normalized_title = normalize_for_comparison(title);
    let distance = strsim::jaro(normalized_expected, &normalized_title);
    if distance < TITLE_MATCH_THRESHOLD {
        CompareOutcome::Mismatch
    } else {
        CompareOutcome::Match
    }
}

fn normalize_for_comparison(title: &str) -> String {
    let lowered = title.to_lowercase();
    let with_translit = normalize_unicode(&lowered);
    let underscores = with_translit.replace('_', " ");
    let non_word = non_word_regex().replace_all(&underscores, "");
    let no_articles = article_regex().replace_all(&non_word, "");
    let spaces = whitespace_regex().replace_all(&no_articles, " ");
    spaces.trim().to_string()
}

fn normalize_unicode(s: &str) -> String {
    let pre = s
        .replace('ä', "ae")
        .replace('ö', "oe")
        .replace('ü', "ue")
        .replace('ß', "ss");
    // NFD decomposition + strip combining marks
    let decomposed: String = pre.nfd().collect();
    decomposed
        .chars()
        .filter(|c| !unicode_normalization::char::is_combining_mark(*c))
        .collect()
}

fn reject_zero_title_match(
    ranked: Vec<RankedResult>,
    search_query: Option<&str>,
) -> Vec<RankedResult> {
    let Some(q) = search_query else {
        return ranked;
    };
    if q.is_empty() {
        return ranked;
    }
    ranked
        .into_iter()
        .filter(|r| r.breakdown.title_match > 0.0)
        .collect()
}

fn sort_by_score_and_preferences(ranked: &mut [RankedResult], preferred: Option<&[String]>) {
    match preferred {
        None | Some([]) => {
            ranked.sort_by(|a, b| {
                b.score
                    .partial_cmp(&a.score)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
        }
        Some(prefs) => {
            ranked.sort_by(|a, b| {
                let ai = quality_preference_index(&a.result, prefs);
                let bi = quality_preference_index(&b.result, prefs);
                ai.cmp(&bi).then_with(|| {
                    b.score
                        .partial_cmp(&a.score)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
            });
        }
    }
}

fn quality_preference_index(result: &SearchResult, preferred: &[String]) -> usize {
    let Some(q) = &result.quality else {
        return 999;
    };
    let Some(res) = &q.resolution else {
        return 999;
    };
    preferred.iter().position(|p| p == res).unwrap_or(999)
}

/// Full breakdown for a single result. Public so workers / admin views
/// can show the scoring components.
#[must_use]
pub fn calculate_score_breakdown(result: &SearchResult, opts: &RankingOptions) -> ScoreBreakdown {
    let scorer_opts = ScoreOpts {
        quality_profile: opts.quality_profile.clone(),
        media_type: Some(opts.media_type.unwrap_or(MediaType::Movie)),
        search_query: opts.search_query.clone(),
    };

    let details = score_result_with_breakdown(result, &scorer_opts);
    let breakdown = &details.breakdown;
    let quality_score = breakdown.get("quality_score").copied().unwrap_or(0.0);
    let seeder_score = breakdown.get("seeder_score").copied().unwrap_or(0.0);
    let title_bonus = breakdown.get("title_bonus").copied().unwrap_or(0.0);

    let tag_bonus = calculate_tag_bonus(&result.title, &opts.preferred_tags);

    ScoreBreakdown {
        quality: round2(quality_score),
        seeders: round2(seeder_score),
        size: 0.0,
        age: 0.0,
        title_match: round2(title_bonus * 100.0),
        tag_bonus: round2(tag_bonus),
        total: round2(details.score + tag_bonus),
    }
}

fn calculate_tag_bonus(title: &str, preferred_tags: &[String]) -> f64 {
    if preferred_tags.is_empty() {
        return 0.0;
    }
    let upper = title.to_uppercase();
    let count = preferred_tags
        .iter()
        .filter(|tag| upper.contains(&tag.to_uppercase()))
        .count();
    #[allow(clippy::cast_precision_loss)]
    let bonus = count as f64 * 10.0;
    bonus
}

fn bytes_to_mb(bytes: u64) -> f64 {
    bytes as f64 / (1024.0 * 1024.0)
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

// -- regex caches -----------------------------------------------------

fn tv_season_regex() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(?i)\bS\d{1,2}(?:E\d{1,3})?\b").unwrap())
}

fn non_word_regex() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"[^\w\s]").unwrap())
}

fn article_regex() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"\b(the|a|an)\b").unwrap())
}

fn whitespace_regex() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"\s+").unwrap())
}

/// Diagnostic shape returned by [`score_all_with_reasons`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScoreReason {
    pub title: String,
    pub seeders: Option<u32>,
    pub size_mb: f64,
    pub resolution: Option<String>,
    pub score: f64,
    pub status: ScoreStatus,
    pub rejection_reason: Option<String>,
    pub breakdown: Option<ScoreBreakdown>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScoreStatus {
    Accepted,
    Rejected,
}

/// Score every result with its rejection reason (or `None` if accepted).
/// Mirrors `release_ranker.score_all_with_reasons/2`.
#[must_use]
pub fn score_all_with_reasons(
    results: Vec<SearchResult>,
    opts: &RankingOptions,
) -> Vec<ScoreReason> {
    let min_seeders = opts.min_seeders.unwrap_or(DEFAULT_MIN_SEEDERS);
    let min_ratio = opts.min_ratio;
    let size_range = opts.size_range;
    let blocked = &opts.blocked_tags;
    let expected_title = opts.expected_title.as_deref();

    let mut out: Vec<ScoreReason> = results
        .into_iter()
        .map(|r| {
            let size_mb = round2(bytes_to_mb(r.size));
            let resolution = r.quality.as_ref().and_then(|q| q.resolution.clone());

            let reason = rejection_reason(
                &r,
                min_seeders,
                min_ratio,
                size_range,
                blocked,
                expected_title,
            );

            match reason {
                None => {
                    let breakdown = calculate_score_breakdown(&r, opts);
                    ScoreReason {
                        title: r.title.clone(),
                        seeders: r.seeders,
                        size_mb,
                        resolution,
                        score: breakdown.total,
                        status: ScoreStatus::Accepted,
                        rejection_reason: None,
                        breakdown: Some(breakdown),
                    }
                }
                Some(reason) => ScoreReason {
                    title: r.title.clone(),
                    seeders: r.seeders,
                    size_mb,
                    resolution,
                    score: 0.0,
                    status: ScoreStatus::Rejected,
                    rejection_reason: Some(reason),
                    breakdown: None,
                },
            }
        })
        .collect();
    out.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    out
}

fn rejection_reason(
    r: &SearchResult,
    min_seeders: u32,
    min_ratio: Option<f64>,
    size_range: Option<(Option<u64>, Option<u64>)>,
    blocked: &[String],
    expected_title: Option<&str>,
) -> Option<String> {
    if !meets_seeder_minimum(r, min_seeders) {
        return Some(format!("low_seeders: {:?} < {min_seeders}", r.seeders));
    }
    if let Some(ratio) = min_ratio {
        if !meets_ratio_minimum(r, ratio) {
            return Some(format!("low_ratio: < {:.1}%", ratio * 100.0));
        }
    }
    if let Some(range) = size_range {
        if !within_size_range(r, range) {
            return Some(format!("size_out_of_range: {:.1} MB", bytes_to_mb(r.size)));
        }
    }
    if !blocked.is_empty() {
        let lower = r.title.to_lowercase();
        if let Some(tag) = blocked
            .iter()
            .find(|tag| lower.contains(&tag.to_lowercase()))
        {
            return Some(format!("blocked_tag: {tag}"));
        }
    }
    if let Some(expected) = expected_title {
        let trimmed = expected.trim();
        if !trimmed.is_empty() {
            let normalized_expected = normalize_for_comparison(trimmed);
            if matches!(
                parse_and_compare(&r.title, &normalized_expected),
                CompareOutcome::Mismatch
            ) {
                return Some("title_mismatch".into());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::search_result::SearchResultBuilder;

    fn make(title: &str, seeders: Option<u32>, leechers: Option<u32>, size: u64) -> SearchResult {
        SearchResultBuilder {
            title: Some(title.into()),
            size: Some(size),
            seeders,
            leechers,
            download_url: Some("magnet:".into()),
            indexer: Some("T".into()),
            quality: Some(crate::quality_parser::parse(title)),
            ..SearchResultBuilder::new()
        }
        .build()
        .unwrap()
    }

    #[test]
    fn filter_drops_low_seeders() {
        let results = vec![
            make("a 1080p", Some(0), Some(0), 1_000_000_000),
            make("b 1080p", Some(50), Some(0), 1_000_000_000),
        ];
        let opts = RankingOptions {
            min_seeders: Some(10),
            ..RankingOptions::default()
        };
        let kept = filter_acceptable(results, &opts);
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].title, "b 1080p");
    }

    #[test]
    fn filter_drops_blocked_tag() {
        let results = vec![
            make("Movie CAM 480p", Some(5), Some(0), 1_000_000_000),
            make("Movie 1080p BluRay", Some(5), Some(0), 1_000_000_000),
        ];
        let opts = RankingOptions {
            blocked_tags: vec!["CAM".into()],
            ..RankingOptions::default()
        };
        let kept = filter_acceptable(results, &opts);
        assert_eq!(kept.len(), 1);
        assert!(!kept[0].title.contains("CAM"));
    }

    #[test]
    fn movie_filter_rejects_tv_season_titles() {
        let results = vec![
            make(
                "Frozen Planet II S01 1080p",
                Some(10),
                Some(0),
                1_000_000_000,
            ),
            make("Frozen 2013 1080p BluRay", Some(10), Some(0), 1_000_000_000),
        ];
        let kept = reject_tv_releases_for_movies(results, Some(MediaType::Movie));
        assert_eq!(kept.len(), 1);
        assert!(kept[0].title.starts_with("Frozen 2013"));
    }

    #[test]
    fn ranking_orders_by_preferred_qualities_first() {
        let results = vec![
            make("Movie 720p WEB-DL", Some(100), Some(0), 1_000_000_000),
            make("Movie 1080p BluRay", Some(50), Some(0), 1_000_000_000),
        ];
        let opts = RankingOptions {
            preferred_qualities: Some(vec!["1080p".into(), "720p".into()]),
            ..RankingOptions::default()
        };
        let ranked = rank_all(results, &opts);
        // 1080p preferred over 720p even with fewer seeders
        assert!(ranked[0].result.title.contains("1080p"));
    }

    #[test]
    fn select_best_returns_none_when_filtered_out() {
        let results = vec![make("Movie", Some(0), Some(0), 1_000_000_000)];
        let opts = RankingOptions {
            min_seeders: Some(10),
            ..RankingOptions::default()
        };
        assert!(select_best_result(results, &opts).is_none());
    }
}
