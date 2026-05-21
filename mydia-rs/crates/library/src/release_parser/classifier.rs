//! Per-token classification — Rust port of
//! `lib/mydia/library/release_parser/classifier.ex` (simplified).
//!
//! The classifier walks each token, consults [`super::vocabulary`],
//! and emits zero or more [`Candidate`]s tagged with the zone
//! relative to the title-boundary anchor. The resolver later picks a
//! consistent assignment.

use regex::Regex;
use std::sync::LazyLock;

use super::candidate::{Candidate, CandidateLabel, CandidateValue, Zone};
use super::tokenizer::{Anchors, Token};
use super::vocabulary;

static YEAR_DIGIT_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(19\d{2}|20\d{2})$").unwrap());
static RESOLUTION_TOKEN_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^(?:480|540|576|720|1080|1440|2160|4320)[pi]$").unwrap());
static SE_PATTERN_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^S(\d{1,3})(?:[-\s.]?E(\d{1,4})(?:[-\s.]?E(\d{1,4}))?)?$").unwrap()
});
static NXM_PATTERN_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^(\d{1,3})x(\d{1,4})$").unwrap());
static EPISODE_ONLY_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^E(\d{1,4})$").unwrap());
static SEASON_WORD_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^Season$").unwrap());

/// Classify every token. The returned vector is keyed by token index
/// — `result[i]` carries the candidates for `tokens[i]`.
#[must_use]
pub fn classify(tokens: &[Token], anchors: &Anchors) -> Vec<Vec<Candidate>> {
    let mut all = Vec::with_capacity(tokens.len());
    let total_len = tokens.last().map_or(0, Token::end_offset);
    let title_boundary = anchors.title_boundary(total_len);

    for (idx, token) in tokens.iter().enumerate() {
        let zone = if token.byte_offset < title_boundary {
            Zone::Title
        } else {
            Zone::Metadata
        };
        let mut candidates = classify_token(idx, token, zone);
        // Combined "Season N" — look ahead.
        if SEASON_WORD_RE.is_match(&token.value) {
            if let Some(next) = tokens.get(idx + 1) {
                if let Ok(n) = next.value.parse::<i32>() {
                    candidates.push(Candidate {
                        token_index: idx,
                        label: CandidateLabel::SeasonMarker,
                        confidence: 0.9,
                        zone,
                        value: Some(CandidateValue::SeasonRef(n)),
                    });
                }
            }
        }
        all.push(candidates);
    }
    all
}

fn classify_token(idx: usize, token: &Token, zone: Zone) -> Vec<Candidate> {
    let mut out = Vec::new();
    let value = token.value.as_str();

    // Year
    if let Some(caps) = YEAR_DIGIT_RE.captures(value) {
        let n: i32 = caps.get(1).expect("year").as_str().parse().unwrap_or(0);
        if (1900..=2099).contains(&n) {
            out.push(Candidate {
                token_index: idx,
                label: CandidateLabel::Year,
                confidence: 0.95,
                zone,
                value: Some(CandidateValue::YearValue(n)),
            });
        }
    }

    // Resolution
    if RESOLUTION_TOKEN_RE.is_match(value) {
        let lower = value.to_lowercase();
        out.push(Candidate {
            token_index: idx,
            label: CandidateLabel::Resolution,
            confidence: 0.95,
            zone,
            value: Some(CandidateValue::StringValue(lower)),
        });
    } else {
        let lower = value.to_lowercase();
        if lower == "4k" || lower == "8k" || lower == "uhd" {
            out.push(Candidate {
                token_index: idx,
                label: CandidateLabel::Resolution,
                confidence: 0.9,
                zone,
                value: Some(CandidateValue::StringValue(value.to_owned())),
            });
        }
    }

    // SxxExx-style episode markers
    if let Some(caps) = SE_PATTERN_RE.captures(value) {
        let season: i32 = caps
            .get(1)
            .and_then(|m| m.as_str().parse().ok())
            .unwrap_or(0);
        let mut episodes = Vec::new();
        if let Some(e1) = caps.get(2).and_then(|m| m.as_str().parse::<i32>().ok()) {
            episodes.push(e1);
        }
        if let Some(e2) = caps.get(3).and_then(|m| m.as_str().parse::<i32>().ok()) {
            // Expand the range (S01E01-E03 -> [1, 2, 3]).
            if let Some(&start) = episodes.first() {
                if e2 > start && (e2 - start) <= 50 {
                    for n in (start + 1)..=e2 {
                        episodes.push(n);
                    }
                } else {
                    episodes.push(e2);
                }
            } else {
                episodes.push(e2);
            }
        }
        out.push(Candidate {
            token_index: idx,
            label: CandidateLabel::EpisodeMarker,
            confidence: 0.98,
            zone,
            value: Some(CandidateValue::EpisodeRef {
                season: Some(season),
                episodes,
            }),
        });
    }

    // NxM-style episode markers
    if let Some(caps) = NXM_PATTERN_RE.captures(value) {
        let season: i32 = caps
            .get(1)
            .and_then(|m| m.as_str().parse().ok())
            .unwrap_or(0);
        let episode: i32 = caps
            .get(2)
            .and_then(|m| m.as_str().parse().ok())
            .unwrap_or(0);
        out.push(Candidate {
            token_index: idx,
            label: CandidateLabel::EpisodeMarker,
            confidence: 0.92,
            zone,
            value: Some(CandidateValue::EpisodeRef {
                season: Some(season),
                episodes: vec![episode],
            }),
        });
    }

    // E-only episode markers
    if let Some(caps) = EPISODE_ONLY_RE.captures(value) {
        let episode: i32 = caps
            .get(1)
            .and_then(|m| m.as_str().parse().ok())
            .unwrap_or(0);
        out.push(Candidate {
            token_index: idx,
            label: CandidateLabel::EpisodeMarker,
            confidence: 0.85,
            zone,
            value: Some(CandidateValue::EpisodeRef {
                season: None,
                episodes: vec![episode],
            }),
        });
    }

    // Season-only token like `S02`
    if let Some(rest) = strip_prefix_ci(value, "S") {
        if !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit()) {
            if let Ok(n) = rest.parse::<i32>() {
                if (1..=99).contains(&n) {
                    out.push(Candidate {
                        token_index: idx,
                        label: CandidateLabel::SeasonMarker,
                        confidence: 0.75,
                        zone,
                        value: Some(CandidateValue::SeasonRef(n)),
                    });
                }
            }
        }
    }

    // Vocabulary lookups
    if vocabulary::is_source(value) {
        out.push(Candidate {
            token_index: idx,
            label: CandidateLabel::Source,
            confidence: 0.9,
            zone,
            value: Some(CandidateValue::StringValue(value.to_owned())),
        });
    }
    if vocabulary::is_codec(value) {
        out.push(Candidate {
            token_index: idx,
            label: CandidateLabel::Codec,
            confidence: 0.9,
            zone,
            value: Some(CandidateValue::StringValue(value.to_owned())),
        });
    }
    if vocabulary::is_hdr(value) {
        out.push(Candidate {
            token_index: idx,
            label: CandidateLabel::Hdr,
            confidence: 0.85,
            zone,
            value: Some(CandidateValue::StringValue(value.to_owned())),
        });
    }
    if vocabulary::is_streaming_service(value) {
        out.push(Candidate {
            token_index: idx,
            label: CandidateLabel::StreamingService,
            confidence: 0.8,
            zone,
            value: Some(CandidateValue::StringValue(value.to_owned())),
        });
    }
    if vocabulary::is_audio_root(value) {
        out.push(Candidate {
            token_index: idx,
            label: CandidateLabel::Audio,
            confidence: 0.7,
            zone,
            value: Some(CandidateValue::StringValue(value.to_owned())),
        });
    }
    // Audio compound like DDP5.1 / DD5.1
    if AUDIO_COMPOUND_RE.is_match(value) {
        out.push(Candidate {
            token_index: idx,
            label: CandidateLabel::Audio,
            confidence: 0.9,
            zone,
            value: Some(CandidateValue::StringValue(value.to_owned())),
        });
    }
    if vocabulary::is_language(value) {
        out.push(Candidate {
            token_index: idx,
            label: CandidateLabel::Language,
            confidence: 0.7,
            zone,
            value: None,
        });
    }
    if vocabulary::is_edition(value) {
        out.push(Candidate {
            token_index: idx,
            label: CandidateLabel::Proper,
            confidence: 0.6,
            zone,
            value: None,
        });
    }

    // Fallback: title candidate when the token sits in the title zone
    // and didn't match anything else with high confidence.
    if zone == Zone::Title && out.is_empty() {
        out.push(Candidate {
            token_index: idx,
            label: CandidateLabel::TitleCandidate,
            confidence: 0.5,
            zone,
            value: None,
        });
    }

    out
}

static AUDIO_COMPOUND_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(?:DD|DDP|AAC|AC3|EAC3|TrueHD|DTS(?:-HD|-X)?)\d+(?:\.\d+)?$").unwrap()
});

fn strip_prefix_ci<'a>(input: &'a str, prefix: &str) -> Option<&'a str> {
    if input.len() < prefix.len() {
        return None;
    }
    if input[..prefix.len()].eq_ignore_ascii_case(prefix) {
        Some(&input[prefix.len()..])
    } else {
        None
    }
}
