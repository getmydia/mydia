//! V3 release-name parser — Rust port of `lib/mydia/library/release_parser/`.
//!
//! The parser turns a filename like
//! `Movie.Name.2020.1080p.BluRay.x264-GROUP.mkv` into a
//! [`ParsedFileInfo`] carrying `title`, `year`, `quality`,
//! `release_group`, and (for TV) `season` + `episodes`.
//!
//! ## Pipeline
//!
//! 1. [`tokenizer::tokenize`] + [`tokenizer::anchor_positions`] —
//!    byte-safe token split, identify year / resolution / episode
//!    anchors.
//! 2. [`classifier::classify`] — label each token (title candidate,
//!    quality marker, release group, ...).
//! 3. [`resolver::resolve`] — pick a globally consistent assignment
//!    and infer the media type.
//! 4. [`quality_extractor::extract`] — gather quality fields from
//!    classified tokens.
//! 5. [`title_assembler`] — stitch the title-zone tokens back into a
//!    human-readable string.
//!
//! ## Scope
//!
//! The U16 port aims for the canonical test cases (clean release
//! names, common scene patterns, sample-rate-card releases). Deeper
//! corpus parity (anime fansubs, Windows path patterns) is deferred
//! to a follow-up — the Phoenix corpus test runs ~13k LOC of parser
//! logic with extensive carve-outs that benefit from incremental
//! parity work alongside the corpus diffs. The
//! [`tests/release_parser.rs`](../../tests/release_parser.rs)
//! integration test is the source-of-truth for the cases the port
//! currently covers.

pub mod candidate;
pub mod classifier;
pub mod quality_extractor;
pub mod resolver;
pub mod target_context;
pub mod title_assembler;
pub mod tokenizer;
pub mod vocabulary;

use serde::{Deserialize, Serialize};

pub use candidate::{Candidate, CandidateLabel, Zone};
pub use target_context::TargetContext;
pub use tokenizer::{Anchors, Token};

/// Media kind inferred from a release name. Mirrors Elixir's
/// `:movie | :tv_show | :unknown`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum MediaKind {
    Movie,
    TvShow,
    #[default]
    Unknown,
}

/// Quality fields parsed from a release name. Field names follow the
/// `Mydia.Library.Structs.Quality` Elixir struct.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Quality {
    pub resolution: Option<String>,
    pub source: Option<String>,
    pub codec: Option<String>,
    pub hdr_format: Option<String>,
    pub audio: Option<String>,
}

impl Quality {
    #[must_use]
    pub fn empty(&self) -> bool {
        self.resolution.is_none()
            && self.source.is_none()
            && self.codec.is_none()
            && self.hdr_format.is_none()
            && self.audio.is_none()
    }
}

/// Result of a parse — the equivalent of `Mydia.Library.Structs.ParsedFileInfo`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParsedFileInfo {
    pub kind: MediaKind,
    pub title: Option<String>,
    pub year: Option<i32>,
    pub season: Option<i32>,
    pub episodes: Option<Vec<i32>>,
    pub quality: Quality,
    pub release_group: Option<String>,
    pub confidence: f64,
    pub original_filename: String,
}

impl ParsedFileInfo {
    /// Build a zero-confidence "we couldn't parse anything" result.
    #[must_use]
    pub fn unknown(original: impl Into<String>) -> Self {
        Self {
            kind: MediaKind::Unknown,
            title: None,
            year: None,
            season: None,
            episodes: None,
            quality: Quality::default(),
            release_group: None,
            confidence: 0.0,
            original_filename: original.into(),
        }
    }
}

/// Options accepted by [`ReleaseParser::parse_with_opts`].
#[derive(Debug, Clone, Default)]
pub struct ParseOptions {
    /// When `Some`, lock title / kind / year to the provided target
    /// rather than inferring them from the release name. Mirrors the
    /// Elixir `:target` opt.
    pub target: Option<TargetContext>,
}

/// Public facade. Mirrors `Mydia.Library.ReleaseParser`.
#[derive(Debug, Default, Clone, Copy)]
pub struct ReleaseParser;

impl ReleaseParser {
    /// Parse a filename (or full path — we strip down to basename
    /// internally, matching Elixir).
    #[must_use]
    pub fn parse(filename: &str) -> ParsedFileInfo {
        Self::parse_with_opts(filename, &ParseOptions::default())
    }

    /// Parse with explicit options. The current port honors
    /// [`ParseOptions::target`] for type/title/year locking and the
    /// `known_seasons` season-range hint; other Elixir options
    /// (`standardize`, `folder_context`) are deferred to follow-ups.
    #[must_use]
    pub fn parse_with_opts(filename: &str, opts: &ParseOptions) -> ParsedFileInfo {
        let basename = basename_of(filename);

        if basename.is_empty() {
            return ParsedFileInfo::unknown(filename);
        }

        // Strip a trailing `-GROUP` release-group marker before
        // tokenizing so the tokenizer sees a clean separator.
        let (prepared, detected_group) = strip_trailing_release_group(&basename);

        let tokens = tokenizer::tokenize(&prepared);
        let anchors = tokenizer::anchor_positions(&prepared);
        let classified = classifier::classify(&tokens, &anchors);
        let mut resolved = resolver::resolve(
            &prepared,
            &tokens,
            &classified,
            &anchors,
            opts.target.as_ref(),
        );

        if resolved.release_group.is_none() {
            resolved.release_group = detected_group;
        }

        let quality = quality_extractor::extract(&tokens, &classified);

        // Type inference fallback for the cases the resolver leaves
        // as `Unknown` — mirrors the `cond` block in `release_parser.ex`.
        let kind = match resolved.kind {
            MediaKind::TvShow => MediaKind::TvShow,
            MediaKind::Movie => MediaKind::Movie,
            MediaKind::Unknown
                if resolved.season.is_some()
                    || resolved.episodes.as_ref().is_some_and(|v| !v.is_empty()) =>
            {
                MediaKind::TvShow
            }
            MediaKind::Unknown => infer_kind(resolved.title.as_deref(), resolved.year, &quality),
        };

        let confidence = confidence_for(
            kind,
            resolved.title.as_deref(),
            resolved.year,
            resolved.season,
            resolved.episodes.as_deref(),
            &quality,
        );

        ParsedFileInfo {
            kind,
            title: resolved.title,
            year: resolved.year,
            season: resolved.season,
            episodes: match resolved.episodes {
                Some(v) if v.is_empty() => None,
                v => v,
            },
            quality,
            release_group: resolved.release_group,
            confidence,
            original_filename: filename.to_owned(),
        }
    }
}

/// `Path::basename` — but we only need the last path component, and
/// we keep it as a string the parser can chew on. Phoenix's
/// `Path.basename/1` is what the call sites pass into the parser, so
/// matching that contract keeps the port honest.
fn basename_of(path: &str) -> String {
    let cleaned = path.trim_end_matches('/');
    match cleaned.rsplit_once('/') {
        Some((_, last)) => last.to_owned(),
        None => cleaned.to_owned(),
    }
}

fn infer_kind(title: Option<&str>, year: Option<i32>, quality: &Quality) -> MediaKind {
    let has_year = year.is_some();
    let has_quality =
        !quality.empty() && (quality.resolution.is_some() || quality.source.is_some());
    let _has_good_title = title.is_some_and(|t| t.len() > 3);

    if has_year || has_quality {
        MediaKind::Movie
    } else {
        MediaKind::Unknown
    }
}

fn confidence_for(
    kind: MediaKind,
    title: Option<&str>,
    year: Option<i32>,
    season: Option<i32>,
    episodes: Option<&[i32]>,
    quality: &Quality,
) -> f64 {
    match kind {
        MediaKind::TvShow => {
            let mut score: f64 = 0.6;
            if title.is_some_and(|t| !t.is_empty()) {
                score += 0.15;
            }
            if season.is_some() {
                score += 0.1;
            }
            if episodes.is_some_and(|v| !v.is_empty()) {
                score += 0.1;
            }
            if quality.resolution.is_some() {
                score += 0.05;
            }
            score.min(1.0)
        }
        MediaKind::Movie => {
            let has_good_title = title.is_some_and(|t| t.len() > 3);
            let has_year = year.is_some();
            let has_quality =
                !quality.empty() && (quality.resolution.is_some() || quality.source.is_some());

            let base: f64 = if !has_good_title && !has_year && !has_quality {
                0.0
            } else if !has_year && !has_quality {
                0.2
            } else {
                0.5
            };

            let mut score: f64 = base;
            if has_good_title {
                score += 0.2;
            }
            if has_year {
                score += 0.15;
            }
            if quality.resolution.is_some() {
                score += 0.1;
            }
            if quality.source.is_some() {
                score += 0.05;
            }
            score.min(1.0)
        }
        MediaKind::Unknown => 0.0,
    }
}

use regex::Regex;
use std::sync::LazyLock;

// Trailing release-group marker — matches the Elixir
// `@release_group_re`. The pattern looks for a separator (dot,
// hyphen, or 2+ spaces) followed by an all-caps token (optionally a
// dotted compound) optionally followed by a bracketed site tag.
static RELEASE_GROUP_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?:[-.]|\s{2,})([A-Z0-9]+(?:[.\s][A-Z0-9]+)?)(?:\[[^\]]+\])?\s*$").unwrap()
});

static COMBINED_MARKER_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^\d{3,4}[piIK]?\.[A-Z0-9]+$").unwrap());
static DDP_DD_CHANNEL_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^DDP?\d+(?:\.\d+)?$").unwrap());
static DOTTED_CODEC_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^(?:[HX]\.?\d{3}|HEVC|AVC)$").unwrap());
static CONTAINS_RESOLUTION_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(?:480p|540p|576p|720p|1080p|1440p|2160p|4320p|4K|8K|UHD)\b").unwrap()
});
static EPISODE_MARKER_IN_GROUP_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^(?:S\d{1,3}E\d{1,4}|E\d{1,4})").unwrap());

const QUALITY_MARKER_WORDS: &[&str] = &[
    "web",
    "bluray",
    "bdrip",
    "brrip",
    "webrip",
    "webdl",
    "hdtv",
    "dvd",
    "dvdrip",
    "dvdscr",
    "remux",
    "hdr",
    "hdr10",
    "dolbyvision",
    "dovi",
    "dv",
    "atmos",
    "dts",
    "dts-x",
    "dts-hd",
    "truehd",
    "aac",
    "ac3",
    "dd",
    "ddp",
    "eac3",
    "hevc",
    "avc",
    "xvid",
    "divx",
    "vp9",
    "av1",
    "nvenc",
    "opus",
    "flac",
    "mp3",
    "x264",
    "x265",
    "h264",
    "h265",
    "proper",
    "repack",
    "internal",
    "limited",
    "unrated",
    "extended",
    "theatrical",
    "hybrid",
    "amzn",
    "nf",
    "atvp",
    "dsnp",
    "hmax",
    "hulu",
    "pmtp",
    "pcok",
    "stan",
    "4k",
    "8k",
    "uhd",
    "720p",
    "1080p",
    "2160p",
    "480p",
    "540p",
    "576p",
    "1440p",
    "4320p",
];

const KNOWN_COMPOUND_SUFFIXES: &[&str] = &["LC", "HD", "DL", "RIP", "X", "MA", "265", "264"];

/// Detect a trailing `-GROUP` release-group marker. Returns the
/// rewritten filename (separator turned to space) plus the detected
/// group, mirroring the Elixir `strip_trailing_release_group/1`.
fn strip_trailing_release_group(filename: &str) -> (String, Option<String>) {
    let stripped = tokenizer::drop_extension(filename);
    let normalized = normalize_dots_underscores(&stripped);

    let Some(captures) = RELEASE_GROUP_RE.captures(&normalized) else {
        return (filename.to_owned(), None);
    };
    let m = captures.get(0).expect("match");
    let g = captures.get(1).expect("capture");

    let group_text = g.as_str();
    let upper = group_text.to_uppercase();
    if KNOWN_COMPOUND_SUFFIXES.contains(&upper.as_str()) {
        return (filename.to_owned(), None);
    }

    if !is_valid_release_group(group_text) {
        return (filename.to_owned(), None);
    }

    // Rewrite: only flatten the first character of the matched
    // separator to a space, leave the rest alone. Use byte offsets
    // since `normalized` shares leading bytes with `stripped`.
    let full_start = m.start();
    if full_start >= stripped.len() {
        return (filename.to_owned(), Some(group_text.to_owned()));
    }
    let before = &stripped[..full_start];
    let suffix_start = full_start + 1;
    let after = if suffix_start <= stripped.len() {
        &stripped[suffix_start..]
    } else {
        ""
    };
    let rewritten = format!("{before} {after}");

    (rewritten, Some(group_text.to_owned()))
}

fn normalize_dots_underscores(input: &str) -> String {
    input
        .chars()
        .map(|c| if c == '.' || c == '_' { ' ' } else { c })
        .collect()
}

fn is_valid_release_group(group: &str) -> bool {
    let lower = group.to_lowercase();
    if QUALITY_MARKER_WORDS.contains(&lower.as_str()) {
        return false;
    }
    if COMBINED_MARKER_RE.is_match(group)
        || DDP_DD_CHANNEL_RE.is_match(group)
        || DOTTED_CODEC_RE.is_match(group)
        || CONTAINS_RESOLUTION_RE.is_match(group)
        || EPISODE_MARKER_IN_GROUP_RE.is_match(group)
    {
        return false;
    }
    group.len() >= 2
}
