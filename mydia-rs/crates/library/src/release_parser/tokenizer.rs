//! Byte-safe tokenizer — Rust port of
//! `lib/mydia/library/release_parser/tokenizer.ex`.
//!
//! Tokens carry **byte offsets** (not grapheme indices) into the
//! input so multi-byte UTF-8 (Japanese, Cyrillic, accented Latin)
//! round-trips through `&input[start..start+len]`. Phoenix's Frieren
//! S02 regression came from mixing byte and grapheme indices; the
//! port preserves the same invariant.

use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::LazyLock;

/// Bracket context — `None` for a bare token, otherwise the enclosing
/// bracket kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BracketContext {
    Bracket,
    Paren,
    Brace,
}

/// One lexical unit produced by the tokenizer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Token {
    pub value: String,
    pub byte_offset: usize,
    pub byte_length: usize,
    pub bracket: Option<BracketContext>,
}

impl Token {
    #[must_use]
    pub fn end_offset(&self) -> usize {
        self.byte_offset + self.byte_length
    }
}

/// Anchor byte positions identified by the tokenizer. The lowest of
/// these forms the title-zone upper boundary.
#[derive(Debug, Clone, Copy, Default)]
pub struct Anchors {
    pub year: Option<usize>,
    pub resolution: Option<usize>,
    pub episode_marker: Option<usize>,
}

impl Anchors {
    /// Lowest set anchor, or `len` when no anchor is present.
    #[must_use]
    pub fn title_boundary(&self, len: usize) -> usize {
        [self.year, self.resolution, self.episode_marker]
            .into_iter()
            .flatten()
            .min()
            .unwrap_or(len)
    }
}

const KNOWN_EXTENSIONS: &[&str] = &[
    "mkv", "mp4", "avi", "mov", "m4v", "ts", "webm", "flv", "wmv", "mpg", "mpeg", "vob", "ogv",
    "3gp", "f4v", "rm", "rmvb", "mp3", "m4a", "flac", "aac", "ogg", "opus", "wav", "srt", "ass",
    "ssa", "sub", "idx", "vtt",
];

/// Compounds that Phoenix's tokenizer splits but our resolver does
/// not reconstruct. Keeping these intact lets `WEB-DL` match as a
/// single source token via the vocabulary table — equivalent to
/// Phoenix's later classifier step that re-attaches the halves.
#[allow(dead_code)]
const COMPOUND_DASHES: &[&str] = &[];

static EXT_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\.([A-Za-z0-9]{1,5})$").unwrap());

// Year-anchor regexes mirror Elixir. The "primary" variant requires
// brackets/parens around the digits, the "secondary" variant accepts
// a bare year that is not part of a longer digit run.
static YEAR_RE_PRIMARY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[\(\[](19\d{2}|20\d{2})[\)\]]").unwrap());
static YEAR_RE_SECONDARY: LazyLock<Regex> = LazyLock::new(|| {
    // Rust's regex crate lacks lookaround; emulate `(?<![0-9])YYYY(?![0-9])`
    // by scanning all matches and picking the first whose neighbours
    // are non-digits. We do this in `secondary_year_pos`.
    Regex::new(r"(19\d{2}|20\d{2})").unwrap()
});

static RESOLUTION_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)((?:480|540|576|720|1080|1440|2160|4320)[pi]|4K|8K|UHD)").unwrap()
});

// Episode markers — same set as Elixir, but with the lookaround
// constraints emulated in `episode_marker_pos`. The trailing
// multi-episode group requires an explicit `E` prefix so a release
// like `S01E05.1080p` doesn't get matched as `S01E05.1080` (Rust's
// regex crate is greedy and lacks lookaround backtracking).
static EP_S_E: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)S\d{1,3}[-\s.]?E\d{1,4}(?:[-\s.]?E\d{1,4})*").unwrap());
static EP_NUM_X: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\d{1,3}x\d{1,4}").unwrap());
static EP_S_ONLY: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)S\d{1,3}").unwrap());
static EP_SEASON_WORD: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\bSeason[\s._]+\d{1,3}\b").unwrap());

/// Drop a known media/subtitle extension from the input.
pub fn drop_extension(input: &str) -> String {
    let Some(caps) = EXT_RE.captures(input) else {
        return input.to_owned();
    };
    let ext_match = caps.get(0).expect("full match");
    let inner = caps.get(1).expect("ext").as_str().to_lowercase();
    if KNOWN_EXTENSIONS.contains(&inner.as_str()) {
        input[..ext_match.start()].to_owned()
    } else {
        input.to_owned()
    }
}

/// Tokenize the input. Extension is dropped first.
#[must_use]
pub fn tokenize(input: &str) -> Vec<Token> {
    let stripped = drop_extension(input);
    let raw = scan(&stripped);
    apply_compound_dash_splits(raw)
}

/// Identify anchor positions.
#[must_use]
pub fn anchor_positions(input: &str) -> Anchors {
    let stripped = drop_extension(input);
    let bytes = stripped.as_bytes();

    let episode_marker = earliest_pos(
        &stripped,
        &[
            episode_marker_pos(&stripped, EpisodePattern::SeasonEpisode),
            episode_marker_pos(&stripped, EpisodePattern::NxM),
            episode_marker_pos(&stripped, EpisodePattern::SeasonOnly),
            EP_SEASON_WORD.find(&stripped).map(|m| m.start()),
        ],
    );

    let primary_year = YEAR_RE_PRIMARY.captures(&stripped).map(|c| {
        let m = c.get(1).expect("year capture");
        m.start()
    });

    let year = primary_year.or_else(|| secondary_year_pos(&stripped, bytes));

    let resolution = resolution_pos(&stripped, bytes);

    Anchors {
        year: year_after_episode_only(year, episode_marker, primary_year),
        resolution,
        episode_marker,
    }
}

fn earliest_pos(_input: &str, candidates: &[Option<usize>]) -> Option<usize> {
    candidates.iter().copied().flatten().min()
}

#[derive(Debug, Clone, Copy)]
enum EpisodePattern {
    SeasonEpisode,
    NxM,
    SeasonOnly,
}

fn episode_marker_pos(input: &str, pattern: EpisodePattern) -> Option<usize> {
    let bytes = input.as_bytes();
    let re: &Regex = match pattern {
        EpisodePattern::SeasonEpisode => &EP_S_E,
        EpisodePattern::NxM => &EP_NUM_X,
        EpisodePattern::SeasonOnly => &EP_S_ONLY,
    };
    for m in re.find_iter(input) {
        let start = m.start();
        let end = m.end();
        let prev_ok = start == 0 || !bytes[start - 1].is_ascii_alphabetic();
        let next_ok = match pattern {
            EpisodePattern::SeasonEpisode => {
                end >= bytes.len() || !bytes[end].is_ascii_alphabetic()
            }
            EpisodePattern::NxM | EpisodePattern::SeasonOnly => {
                end >= bytes.len() || !bytes[end].is_ascii_alphanumeric()
            }
        };
        if prev_ok && next_ok {
            return Some(start);
        }
    }
    None
}

fn secondary_year_pos(input: &str, bytes: &[u8]) -> Option<usize> {
    for m in YEAR_RE_SECONDARY.find_iter(input) {
        let s = m.start();
        let e = m.end();
        let prev_ok = s == 0 || !bytes[s - 1].is_ascii_digit();
        let next_ok = e >= bytes.len() || !bytes[e].is_ascii_digit();
        if prev_ok && next_ok {
            return Some(s);
        }
    }
    None
}

fn resolution_pos(input: &str, bytes: &[u8]) -> Option<usize> {
    for caps in RESOLUTION_RE.captures_iter(input) {
        let g = caps.get(1).expect("res capture");
        let s = g.start();
        let e = g.end();
        let prev_ok = s == 0 || !bytes[s - 1].is_ascii_alphanumeric();
        let next_ok = e >= bytes.len() || !bytes[e].is_ascii_alphabetic();
        if prev_ok && next_ok {
            return Some(s);
        }
    }
    None
}

// The year-before-episode carve-out from Elixir: only fire when the
// year is at byte position 0 *and* an episode marker appears later
// *and* the year is not parenthesized.
fn year_after_episode_only(
    year: Option<usize>,
    episode: Option<usize>,
    primary_year: Option<usize>,
) -> Option<usize> {
    let y = year?;
    // A parenthesized year always wins.
    if primary_year.is_some() {
        return Some(y);
    }
    // No episode marker -> keep the year.
    let Some(_) = episode else { return Some(y) };
    // Year is at byte 0 AND there's an episode marker later AND
    // there's no parenthesized year -> drop it (it's part of the title).
    if y == 0 {
        return None;
    }
    Some(y)
}

// Byte-level state machine that emits tokens with byte offsets.
fn scan(input: &str) -> Vec<Token> {
    let bytes = input.as_bytes();
    let mut tokens = Vec::new();
    let mut start: Option<usize> = None;
    let mut bracket: Option<BracketContext> = None;
    let mut pos = 0;

    while pos < bytes.len() {
        let b = bytes[pos];
        match b {
            b' ' | b'.' | b'_' | b'\t' => {
                emit_pending(input, &mut tokens, &mut start, pos, bracket);
            }
            b'[' => {
                emit_pending(input, &mut tokens, &mut start, pos, bracket);
                bracket = Some(BracketContext::Bracket);
            }
            b'(' => {
                emit_pending(input, &mut tokens, &mut start, pos, bracket);
                bracket = Some(BracketContext::Paren);
            }
            b'{' => {
                emit_pending(input, &mut tokens, &mut start, pos, bracket);
                bracket = Some(BracketContext::Brace);
            }
            b']' | b')' | b'}' => {
                emit_pending(input, &mut tokens, &mut start, pos, bracket);
                bracket = None;
            }
            _ => {
                if start.is_none() {
                    start = Some(pos);
                }
            }
        }
        pos += 1;
    }
    emit_pending(input, &mut tokens, &mut start, pos, bracket);
    tokens
}

fn emit_pending(
    input: &str,
    tokens: &mut Vec<Token>,
    start: &mut Option<usize>,
    end: usize,
    bracket: Option<BracketContext>,
) {
    if let Some(s) = *start {
        let len = end - s;
        if len > 0 {
            let value = input[s..end].to_owned();
            tokens.push(Token {
                value,
                byte_offset: s,
                byte_length: len,
                bracket,
            });
        }
        *start = None;
    }
}

fn apply_compound_dash_splits(tokens: Vec<Token>) -> Vec<Token> {
    let mut out = Vec::with_capacity(tokens.len());
    for token in tokens {
        let upper = token.value.to_uppercase();
        if COMPOUND_DASHES.contains(&upper.as_str()) {
            if let Some((left, right)) = token.value.split_once('-') {
                let left_len = left.len();
                let right_len = right.len();
                out.push(Token {
                    value: left.to_owned(),
                    byte_offset: token.byte_offset,
                    byte_length: left_len,
                    bracket: token.bracket,
                });
                out.push(Token {
                    value: right.to_owned(),
                    byte_offset: token.byte_offset + left_len + 1,
                    byte_length: right_len,
                    bracket: token.bracket,
                });
                continue;
            }
        }
        out.push(token);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drops_known_extension() {
        assert_eq!(drop_extension("Movie.2020.mkv"), "Movie.2020");
        assert_eq!(drop_extension("Movie.2020.unknown"), "Movie.2020.unknown");
    }

    #[test]
    fn tokenizes_dotted_release() {
        let tokens = tokenize("Movie.Name.2020.1080p.BluRay.x264-GROUP.mkv");
        let values: Vec<_> = tokens.iter().map(|t| t.value.as_str()).collect();
        assert_eq!(
            values,
            vec!["Movie", "Name", "2020", "1080p", "BluRay", "x264-GROUP"]
        );
    }

    #[test]
    fn anchors_identify_year_resolution_episode() {
        let anchors = anchor_positions("Show.Name.S01E05.1080p.WEB-DL.mkv");
        assert!(anchors.episode_marker.is_some());
        assert!(anchors.resolution.is_some());
        // No year in this filename.
        assert!(anchors.year.is_none());
    }

    #[test]
    fn anchors_year_in_parens() {
        let anchors = anchor_positions("Movie Title (2020) 1080p.mkv");
        assert!(anchors.year.is_some());
    }

    #[test]
    fn anchors_handle_byte_positions_for_multibyte() {
        // Japanese release name with a year.
        let anchors = anchor_positions("ファイル名 (2024) 1080p.mkv");
        assert!(anchors.year.is_some());
    }

    #[test]
    fn compound_dash_kept_intact_for_web_dl() {
        // The U16 port intentionally keeps `WEB-DL` as a single
        // token so the vocabulary lookup can match it directly,
        // rather than re-attaching split halves in the classifier
        // (the Phoenix path).
        let tokens = tokenize("Show.S01E05.WEB-DL.mkv");
        let values: Vec<_> = tokens.iter().map(|t| t.value.as_str()).collect();
        assert!(values.iter().any(|v| v.eq_ignore_ascii_case("WEB-DL")));
    }
}
