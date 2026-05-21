//! Unified search-result scoring.
//!
//! Port of `lib/mydia/indexers/search_scorer.ex`. The formula and the
//! constants are intentionally identical — the parallel window relies
//! on automatic search rankings matching the Phoenix implementation.
//!
//! ```text
//! combined = (quality_score * 0.6 + availability_score + title_bonus)
//!            * zero_seeder_penalty
//! ```

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::search_result::{DownloadProtocol, QualityInfo, SearchResult};

/// Caller-provided quality preferences for scoring. The Rust side
/// keeps the profile concrete instead of importing a settings struct
/// since the U17 worker layer will pass through whatever shape it has.
#[derive(Debug, Clone, Default)]
pub struct QualityProfile {
    pub preferred_resolutions: Vec<String>,
}

/// Either `:movie` or `:episode` in Elixir.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaType {
    Movie,
    Episode,
}

/// Options accepted by [`score_result`] and [`score_result_with_breakdown`].
#[derive(Debug, Clone, Default)]
pub struct ScoreOpts {
    pub quality_profile: Option<QualityProfile>,
    pub media_type: Option<MediaType>,
    pub search_query: Option<String>,
}

/// Detailed breakdown returned by [`score_result_with_breakdown`].
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ScoreBreakdownDetails {
    pub score: f64,
    pub breakdown: HashMap<String, f64>,
    pub violations: Vec<String>,
    pub detected: HashMap<String, serde_json::Value>,
}

/// Single-shot scoring — see [`score_result_with_breakdown`] for the breakdown.
#[must_use]
pub fn score_result(result: &SearchResult, opts: &ScoreOpts) -> f64 {
    score_result_with_breakdown(result, opts).score
}

/// Full scoring breakdown for a single result.
#[must_use]
pub fn score_result_with_breakdown(
    result: &SearchResult,
    opts: &ScoreOpts,
) -> ScoreBreakdownDetails {
    let media_type = opts.media_type.unwrap_or(MediaType::Movie);

    let (quality_score, quality_breakdown, violations) =
        score_quality(result, opts.quality_profile.as_ref(), media_type);

    let title_bonus = score_title_match(&result.title, opts.search_query.as_deref());

    let (availability_score, availability_penalty, availability_violations) =
        score_availability(result);

    let combined = (quality_score * 0.6 + availability_score + title_bonus) * availability_penalty;

    let mut breakdown = quality_breakdown;
    breakdown.insert("quality_score".into(), round1(quality_score));
    breakdown.insert("seeder_score".into(), round1(availability_score));
    breakdown.insert("title_bonus".into(), round1(title_bonus));
    breakdown.insert("zero_seeder_penalty".into(), availability_penalty);

    let mut all_violations = violations;
    all_violations.extend(availability_violations);

    ScoreBreakdownDetails {
        score: round1(combined),
        breakdown,
        violations: all_violations,
        detected: extract_detected_quality(result),
    }
}

fn score_availability(result: &SearchResult) -> (f64, f64, Vec<String>) {
    match result.download_protocol {
        Some(DownloadProtocol::Nzb) => {
            let score = score_nzb_availability(result.nzb_completion, result.nzb_grabs);
            (score, 1.0, Vec::new())
        }
        _ => match result.seeders {
            None => (
                0.0,
                0.7,
                vec!["No seeders (30% penalty applied)".to_string()],
            ),
            Some(0) => (
                0.0,
                0.7,
                vec!["No seeders (30% penalty applied)".to_string()],
            ),
            Some(seeders) => (score_seeders(seeders), 1.0, Vec::new()),
        },
    }
}

fn score_nzb_availability(completion: Option<f64>, grabs: Option<u32>) -> f64 {
    let completion = completion.unwrap_or(1.0);
    let completion_score = completion * 30.0;
    let grabs_score = score_grabs(grabs);
    completion_score + grabs_score
}

fn score_grabs(grabs: Option<u32>) -> f64 {
    match grabs {
        None | Some(0) => 0.0,
        Some(g) => (f64::from(g + 1).log10() * 2.0).min(5.0),
    }
}

/// `0..=30` logarithmic mapping of seeder count.
#[must_use]
pub fn score_seeders(seeders: u32) -> f64 {
    if seeders == 0 {
        return 0.0;
    }
    f64::from(seeders + 1).log10() * 10.0
}

/// Title-relevance bonus in the range `0..=10`.
#[must_use]
pub fn score_title_match(title: &str, query: Option<&str>) -> f64 {
    let Some(query) = query else {
        return 0.0;
    };
    if query.is_empty() {
        return 0.0;
    }
    title_relevance_bonus(title, query) / 2.0
}

fn title_relevance_bonus(title: &str, query: &str) -> f64 {
    let query_words = normalize_to_words(query);
    let title_words = normalize_to_words(title);
    if query_words.is_empty() {
        return 0.0;
    }

    let matched = query_words
        .iter()
        .filter(|qw| {
            title_words
                .iter()
                .any(|tw| tw == *qw || tw.starts_with(qw.as_str()) || qw.starts_with(tw.as_str()))
        })
        .count();

    #[allow(clippy::cast_precision_loss)]
    let match_ratio = matched as f64 / query_words.len() as f64;

    let significant_q: Vec<&String> = filter_common_words(&query_words);
    let significant_t: Vec<&String> = filter_common_words(&title_words);
    let starts_with_bonus = match (significant_q.first(), significant_t.first()) {
        (Some(a), Some(b)) if a == b => 5.0,
        _ => 0.0,
    };

    let extra_words = title_words
        .iter()
        .filter(|tw| !query_words.iter().any(|qw| qw == *tw))
        .filter(|tw| !quality_or_episode_word(tw))
        .count();

    #[allow(clippy::cast_precision_loss)]
    let extra_penalty = (extra_words as f64 * 2.0).min(10.0);
    let base_bonus = match_ratio * 15.0;
    (base_bonus + starts_with_bonus - extra_penalty).max(0.0)
}

fn normalize_to_words(text: &str) -> Vec<String> {
    text.to_lowercase()
        .chars()
        .map(|c| if matches!(c, '.' | '_' | '-') { ' ' } else { c })
        .collect::<String>()
        .split_whitespace()
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

fn filter_common_words(words: &[String]) -> Vec<&String> {
    const COMMON: &[&str] = &[
        "the", "a", "an", "of", "and", "or", "in", "on", "at", "to", "for",
    ];
    words
        .iter()
        .filter(|w| !COMMON.contains(&w.as_str()))
        .collect()
}

fn quality_or_episode_word(word: &str) -> bool {
    const QUALITY: &[&str] = &[
        "2160p",
        "1080p",
        "720p",
        "480p",
        "4k",
        "uhd",
        "hd",
        "sd",
        "x264",
        "x265",
        "h264",
        "h265",
        "hevc",
        "avc",
        "av1",
        "bluray",
        "bdrip",
        "brrip",
        "webrip",
        "webdl",
        "web",
        "hdtv",
        "hdrip",
        "dvdrip",
        "remux",
        "proper",
        "repack",
        "dts",
        "atmos",
        "truehd",
        "dolby",
        "aac",
        "ac3",
        "flac",
        "ddp",
        "ddp5",
        "hdr",
        "hdr10",
        "dolbyvision",
        "dv",
        "nf",
        "amzn",
        "atvp",
    ];
    if QUALITY.contains(&word) {
        return true;
    }
    // S01, S01E05, E03
    let ep = regex::Regex::new(r"^(s\d+e?\d*|e\d+|\d{3,4}p)$").unwrap();
    if ep.is_match(word) {
        return true;
    }
    // Year 1900..2099
    let year = regex::Regex::new(r"^(19|20)\d{2}$").unwrap();
    year.is_match(word)
}

/// Quality score plus a breakdown sub-map and violations.
#[must_use]
pub fn score_quality(
    result: &SearchResult,
    profile: Option<&QualityProfile>,
    _media_type: MediaType,
) -> (f64, HashMap<String, f64>, Vec<String>) {
    let mut breakdown = HashMap::new();

    let Some(_profile) = profile else {
        // No profile — availability is the primary quality signal.
        let quality_score = match result.download_protocol {
            Some(DownloadProtocol::Nzb) => {
                let completion = result.nzb_completion.unwrap_or(1.0);
                (completion * 100.0).min(100.0)
            }
            _ => match result.seeders {
                None => 0.0,
                Some(s) => f64::from(s).min(100.0),
            },
        };
        breakdown.insert("raw_quality_score".into(), quality_score);
        return (quality_score, breakdown, Vec::new());
    };

    // With a profile we score based on the parsed `QualityInfo`. The
    // Elixir side delegates to `QualityProfile.score_media_file/2`,
    // which has its own (porting in U5/U17) — here we use a simplified
    // version that mirrors the typical resolution-weighted score.
    let quality_info = result.quality.clone().unwrap_or_default();
    let score = simple_profile_score(&quality_info);
    breakdown.insert("profile_quality".into(), score);
    (score, breakdown, Vec::new())
}

fn simple_profile_score(q: &QualityInfo) -> f64 {
    // Treat the full quality_score scale as already comparable; the
    // 0..100 range expected by the formula is achieved by dividing.
    let raw = crate::quality_parser::quality_score(q);
    f64::from(raw) / 20.0 // ~0..100 typical range
}

fn extract_detected_quality(result: &SearchResult) -> HashMap<String, serde_json::Value> {
    let mut detected = HashMap::new();
    if let Some(q) = &result.quality {
        if let Some(r) = &q.resolution {
            detected.insert("resolution".into(), serde_json::Value::from(r.clone()));
        }
        if let Some(s) = &q.source {
            detected.insert("source".into(), serde_json::Value::from(s.clone()));
        }
        if let Some(c) = &q.codec {
            detected.insert("video_codec".into(), serde_json::Value::from(c.clone()));
        }
        if let Some(a) = &q.audio {
            detected.insert("audio_codec".into(), serde_json::Value::from(a.clone()));
        }
        detected.insert("hdr".into(), serde_json::Value::from(q.hdr));
        if result.size > 0 {
            let mb = result.size as f64 / (1024.0 * 1024.0);
            detected.insert(
                "size_mb".into(),
                serde_json::json!((mb * 10.0).round() / 10.0),
            );
        }
    }
    detected
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::search_result::SearchResultBuilder;

    fn make_result(seeders: Option<u32>, title: &str) -> SearchResult {
        SearchResultBuilder {
            title: Some(title.into()),
            size: Some(1_073_741_824),
            seeders,
            leechers: Some(0),
            download_url: Some("magnet:".into()),
            indexer: Some("Test".into()),
            ..SearchResultBuilder::new()
        }
        .build()
        .unwrap()
    }

    #[test]
    fn score_seeders_log_scale() {
        assert!((score_seeders(0) - 0.0).abs() < f64::EPSILON);
        // log10(11) * 10 ≈ 10.41
        let v = score_seeders(10);
        assert!(v > 10.0 && v < 11.0);
    }

    #[test]
    fn title_match_bonus_starts_with() {
        let bonus = score_title_match("Ubuntu 22.04 LTS 1080p", Some("Ubuntu 22.04"));
        // base + starts_with - extra
        assert!(bonus > 0.0);
    }

    #[test]
    fn zero_seeders_apply_penalty() {
        let r = make_result(Some(0), "Movie 2024 1080p");
        let details = score_result_with_breakdown(&r, &ScoreOpts::default());
        let penalty = details
            .breakdown
            .get("zero_seeder_penalty")
            .copied()
            .unwrap();
        assert!((penalty - 0.7).abs() < f64::EPSILON);
    }

    #[test]
    fn nzb_does_not_apply_zero_seeder_penalty() {
        let mut r = make_result(None, "Movie 2024 1080p");
        r.download_protocol = Some(DownloadProtocol::Nzb);
        r.nzb_completion = Some(1.0);
        let details = score_result_with_breakdown(&r, &ScoreOpts::default());
        let penalty = details
            .breakdown
            .get("zero_seeder_penalty")
            .copied()
            .unwrap();
        assert!((penalty - 1.0).abs() < f64::EPSILON);
    }
}
