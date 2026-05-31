//! Matches media filenames to metadata relay results via multi-pass
//! search — Rust port of `lib/mydia/library/metadata_matcher.ex`
//! (926 LOC).
//!
//! ## Match strategy (in priority order)
//!
//! 1. **External ID lookup** — parse `[tmdb-123]` / `[tvdb-456]` from
//!    parent directory names; fetch by ID directly. Confidence 0.99.
//! 2. **Local DB match** — query existing `media_items` rows by
//!    normalized title + year.
//! 3. **Relay search with year** — `Provider::search()` with extracted
//!    year; select best match by title similarity.
//! 4. **Relay search without year** — fallback when year is unknown or
//!    year-filtered search returns nothing.
//! 5. **Series-level fallback (TV only)** — when episode-level match
//!    confidence is low, attempt series-level match at 0.70 confidence.
//!
//! ## Title normalization
//!
//! Before comparison, titles are stripped of quality tags, codecs,
//! release groups, year patterns, and IMDB/TVDB annotations. Case-
//! insensitive Levenshtein ratio with threshold 0.8 determines
//! high-confidence matches.

use std::sync::Arc;

use mydia_rs_metadata::{FetchOpts, MediaType, Provider, ProviderConfig, SearchOpts};
use regex::Regex;
use sea_orm::sea_query::{Expr, Func};
use sea_orm::{DatabaseConnection, EntityTrait, ExprTrait, QueryFilter};
use std::sync::LazyLock;

use crate::error::LibraryError;
use crate::release_parser::ParsedFileInfo;

// Cache compiled regex for title normalization.
static YEAR_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:19|20)\d{2}").expect("compile year regex"));
static BRACKET_ID_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\[(tmdb|tvdb|imdb)[-_]?(\w+)\]").expect("compile bracket-id regex")
});

/// Confidence threshold for high-confidence title matches.
pub const HIGH_CONFIDENCE_THRESHOLD: f64 = 0.80;

/// Confidence for direct external-ID lookups.
pub const DIRECT_ID_CONFIDENCE: f64 = 0.99;

/// Confidence for series-level fallback matches.
pub const SERIES_LEVEL_CONFIDENCE: f64 = 0.70;

/// How a match was resolved — mirrors Phoenix's `:match_type` atoms.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MatchType {
    DirectIdLookup,
    LocalDatabase,
    SearchWithYear,
    SearchWithoutYear,
    SeriesLevelFallback,
}

/// One candidate match for a media filename.
#[derive(Debug, Clone)]
pub struct MatchCandidate {
    /// Provider-specific identifier (`"123"` for TMDB, `"81189"` for TVDB).
    pub provider_id: String,
    /// Provider type hint (`"tmdb"` or `"tvdb"`).
    pub provider_type: String,
    /// Display title from metadata.
    pub title: String,
    /// Release year, when known.
    pub year: Option<i32>,
    /// `"movie"` or `"tv_show"`.
    pub media_type: String,
    /// 0.0–1.0 confidence.
    pub confidence: f64,
    /// How this match was resolved.
    pub match_type: MatchType,
    /// When `Some`, this is a partial match (eg series-level only).
    pub partial_reason: Option<String>,
}

/// Context needed by the matcher besides the filename. Mirrors the
/// Phoenix `opts` keyword list passed to `MetadataMatcher.match_file/2`.
#[derive(Debug, Clone)]
pub struct MatchContext {
    /// Whether the file is expected to be a movie or TV show.
    pub media_type: Option<MediaType>,
    /// Library path type (`"movies"`, `"series"`, etc.) for
    /// disambiguating mixed-type libraries.
    pub library_type: Option<String>,
}

/// Public facade.
pub struct MetadataMatcher {
    provider: Arc<dyn Provider>,
    config: ProviderConfig,
    db: DatabaseConnection,
}

impl MetadataMatcher {
    pub fn new(
        provider: Arc<dyn Provider>,
        config: ProviderConfig,
        db: DatabaseConnection,
    ) -> Self {
        Self {
            provider,
            config,
            db,
        }
    }

    /// Match a filename against metadata sources. Returns candidates
    /// sorted by descending confidence.
    pub async fn match_file(
        &self,
        parsed: &ParsedFileInfo,
        ctx: &MatchContext,
    ) -> Result<Vec<MatchCandidate>, LibraryError> {
        let mut candidates: Vec<MatchCandidate> = Vec::new();

        // Pass 1: external ID lookup from directory path.
        if let Some(c) = self.external_id_lookup(parsed).await {
            candidates.push(c);
            return Ok(candidates);
        }

        // Pass 2: local DB match.
        if let Some(c) = self.local_db_match(parsed, ctx).await {
            candidates.push(c);
            return Ok(candidates);
        }

        // Determine search media type.
        let media_type = ctx
            .media_type
            .unwrap_or(media_type_from_parsed_kind(parsed));

        // Pass 3: search with year.
        let mut found = self
            .search_match(parsed, &media_type, parsed.year, ctx)
            .await?;
        if !found.is_empty() {
            candidates.append(&mut found);
            return Ok(candidates);
        }

        // Pass 4: search without year.
        let mut found = self.search_match(parsed, &media_type, None, ctx).await?;
        if !found.is_empty() {
            candidates.append(&mut found);
            return Ok(candidates);
        }

        // Pass 5: TV series-level fallback.
        if media_type == MediaType::TvShow {
            if let Some(c) = self.series_level_fallback(parsed, ctx).await? {
                candidates.push(c);
            }
        }

        Ok(candidates)
    }

    // -- Pass 1: External ID lookup -----------------------------------

    async fn external_id_lookup(&self, parsed: &ParsedFileInfo) -> Option<MatchCandidate> {
        let dir = std::path::Path::new(&parsed.original_filename)
            .parent()
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())?;

        let caps = BRACKET_ID_RE.captures(dir)?;
        let provider = caps.get(1)?.as_str();
        let id = caps.get(2)?.as_str();

        let provider_type = match provider {
            "tmdb" => "tmdb",
            "tvdb" => "tvdb",
            _ => return None,
        };

        let fetch_opts = FetchOpts {
            media_type: None,
            provider: Some(provider_type),
            ..FetchOpts::default()
        };

        match self
            .provider
            .fetch_by_id(&self.config, id, &fetch_opts)
            .await
        {
            Ok(metadata) => Some(MatchCandidate {
                provider_id: metadata.provider_id,
                provider_type: provider_type.into(),
                title: metadata.title.unwrap_or_default(),
                year: metadata.year,
                media_type: media_type_to_str(metadata.media_type),
                confidence: DIRECT_ID_CONFIDENCE,
                match_type: MatchType::DirectIdLookup,
                partial_reason: None,
            }),
            Err(_) => None,
        }
    }

    // -- Pass 2: Local DB match ----------------------------------------

    async fn local_db_match(
        &self,
        parsed: &ParsedFileInfo,
        ctx: &MatchContext,
    ) -> Option<MatchCandidate> {
        let query_title = parsed.title.as_deref()?;
        let normalized = normalize_search_query(query_title);

        use mydia_rs_entities::media_items;

        // Find by matching title (case-insensitive).
        let rows = media_items::Entity::find()
            .filter(Expr::expr(
                Func::lower(Expr::col(media_items::Column::Title))
                    .equals(normalized.to_lowercase()),
            ))
            .all(&self.db)
            .await
            .ok()?;

        rows.into_iter().next().map(|row| {
            let row_title = row.title.clone();
            let row_year = row.year;
            let confidence = if row_year == parsed.year { 0.90 } else { 0.70 };
            let media_type = match ctx.media_type {
                Some(MediaType::TvShow) => "tv_show",
                _ => "movie",
            };
            let (provider_id, provider_type) = provider_from_row(&row);
            MatchCandidate {
                provider_id,
                provider_type,
                title: row_title,
                year: row_year,
                media_type: media_type.into(),
                confidence,
                match_type: MatchType::LocalDatabase,
                partial_reason: None,
            }
        })
    }

    // -- Pass 3 & 4: Relay search --------------------------------------

    async fn search_match(
        &self,
        parsed: &ParsedFileInfo,
        media_type: &MediaType,
        year: Option<i32>,
        _ctx: &MatchContext,
    ) -> Result<Vec<MatchCandidate>, LibraryError> {
        let Some(query_title) = parsed.title.as_deref() else {
            return Ok(Vec::new());
        };
        let query = normalize_search_query(query_title);
        if query.is_empty() {
            return Ok(Vec::new());
        }

        let opts = SearchOpts {
            media_type: Some(*media_type),
            year,
            language: Some("en-US".into()),
            ..SearchOpts::default()
        };

        let results = self.provider.search(&self.config, &query, &opts).await?;

        // Score and sort by title similarity.
        let mut candidates: Vec<MatchCandidate> = results
            .into_iter()
            .filter_map(|r| {
                let candidate_title = r.title.as_deref().or(r.name.as_deref())?;
                let similarity = title_similarity(&query, candidate_title);
                if similarity < 0.2 {
                    return None;
                }
                let match_type = if year.is_some() {
                    MatchType::SearchWithYear
                } else {
                    MatchType::SearchWithoutYear
                };
                let confidence = similarity;
                Some(MatchCandidate {
                    provider_id: r.provider_id,
                    provider_type: provider_kind_str(r.provider),
                    title: candidate_title.into(),
                    year: r.year,
                    media_type: media_type_to_str(r.media_type),
                    confidence,
                    match_type,
                    partial_reason: None,
                })
            })
            .collect();

        candidates.sort_by(|a, b| {
            b.confidence
                .partial_cmp(&a.confidence)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        // Keep only high-confidence matches.
        candidates.retain(|c| c.confidence >= HIGH_CONFIDENCE_THRESHOLD);

        Ok(candidates)
    }

    // -- Pass 5: Series-level fallback ---------------------------------

    async fn series_level_fallback(
        &self,
        parsed: &ParsedFileInfo,
        _ctx: &MatchContext,
    ) -> Result<Option<MatchCandidate>, LibraryError> {
        let Some(query_title) = parsed.title.as_deref() else {
            return Ok(None);
        };
        let query = normalize_search_query(query_title);
        if query.is_empty() {
            return Ok(None);
        }

        let opts = SearchOpts {
            media_type: Some(MediaType::TvShow),
            year: parsed.year,
            language: Some("en-US".into()),
            ..SearchOpts::default()
        };

        let results = self.provider.search(&self.config, &query, &opts).await?;

        // Series-level: accept lower similarity threshold.
        let best = results
            .into_iter()
            .filter_map(|r| {
                let candidate_title = r.title.as_deref().or(r.name.as_deref())?;
                let similarity = title_similarity(&query, candidate_title);
                if similarity < 0.50 {
                    return None;
                }
                Some(MatchCandidate {
                    provider_id: r.provider_id,
                    provider_type: provider_kind_str(r.provider),
                    title: candidate_title.into(),
                    year: r.year,
                    media_type: media_type_to_str(r.media_type),
                    confidence: SERIES_LEVEL_CONFIDENCE,
                    match_type: MatchType::SeriesLevelFallback,
                    partial_reason: Some("series_level_fallback".into()),
                })
            })
            .max_by(|a, b| {
                a.confidence
                    .partial_cmp(&b.confidence)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });

        Ok(best)
    }
}

// -- Title normalization ------------------------------------------------

/// Strip quality tags, codecs, release groups, years, and ID
/// annotations from a title, leaving a clean search query.
pub fn normalize_search_query(title: &str) -> String {
    let mut s = title.to_string();

    // Remove bracketed IDs: [tmdb-123], [tvdb-456], [imdb-tt1234567].
    while let Some(pos) = s.find('[') {
        if let Some(end) = s[pos..].find(']') {
            let bracket = &s[pos..=pos + end];
            if BRACKET_ID_RE.is_match(bracket) {
                s.replace_range(pos..=pos + end, "");
                continue;
            }
        }
        break;
    }

    // Replace dots, underscores with spaces.
    s = s.replace(['.', '_'], " ");

    // Remove SxxExx patterns.
    let episode_re = Regex::new(r"(?i)\b[Ss]\d{1,4}\s*[Ee]\d{1,4}(?:[Ee-]\d{1,4})*\b")
        .expect("compile episode regex");
    s = episode_re.replace_all(&s, " ").to_string();

    // Remove year patterns.
    s = YEAR_RE.replace_all(&s, " ").to_string();

    // Strip common quality / codec terms (case-insensitive).
    let quality_terms: &[&str] = &[
        // Resolutions
        "1080p",
        "720p",
        "2160p",
        "480p",
        "576p",
        "4k",
        // Sources
        "bluray",
        "web-dl",
        "webrip",
        "hdtv",
        "dvdrip",
        "brrip",
        "bdrip",
        "web",
        "remux",
        // Codecs
        "x264",
        "x265",
        "h264",
        "h265",
        "hevc",
        "av1",
        "vp9",
        "xvid",
        "divx",
        // Audio
        "aac",
        "ac3",
        "dts",
        "truehd",
        "flac",
        "mp3",
        "ddp",
        "dd\\+",
        "dts-hd",
        "dts-x",
        // Other
        "proper",
        "repack",
        "internal",
        "extended",
        "uncut",
        "dc",
        "remastered",
        "hdr",
        "hdr10",
        "hdr10\\+",
        "dolby vision",
        "dv",
        "sdr",
    ];
    for term in quality_terms {
        let re = Regex::new(&format!(r"(?i)\b{}\b", regex::escape(term)))
            .expect("compile quality term regex");
        s = re.replace_all(&s, " ").to_string();
    }

    // Strip release group (uppercase word at end after last dash).
    if let Some(pos) = s.rfind('-') {
        let after_dash = s[pos + 1..].trim();
        if after_dash
            .chars()
            .all(|c| c.is_uppercase() || c.is_ascii_digit() || c == '_')
        {
            s = s[..pos].trim().to_string();
        }
    }

    // Collapse whitespace.
    s = Regex::new(r"\s+")
        .expect("compile whitespace regex")
        .replace_all(&s, " ")
        .trim()
        .to_string();

    s
}

/// Case-insensitive Levenshtein ratio.
pub fn title_similarity(a: &str, b: &str) -> f64 {
    let a = a.to_lowercase();
    let b = b.to_lowercase();
    if a == b {
        return 1.0;
    }
    let dist = levenshtein_distance(&a, &b);
    let max_len = a.len().max(b.len());
    if max_len == 0 {
        return 1.0;
    }
    1.0 - (dist as f64 / max_len as f64)
}

fn levenshtein_distance(a: &str, b: &str) -> usize {
    let a_chars: Vec<char> = a.chars().collect();
    let b_chars: Vec<char> = b.chars().collect();
    let m = a_chars.len();
    let n = b_chars.len();

    if m == 0 {
        return n;
    }
    if n == 0 {
        return m;
    }

    let mut prev: Vec<usize> = (0..=n).collect();
    let mut curr: Vec<usize> = vec![0; n + 1];

    for i in 1..=m {
        curr[0] = i;
        for j in 1..=n {
            let cost = usize::from(a_chars[i - 1] != b_chars[j - 1]);
            curr[j] = (prev[j] + 1).min(curr[j - 1] + 1).min(prev[j - 1] + cost);
        }
        std::mem::swap(&mut prev, &mut curr);
    }

    prev[n]
}

// -- Helpers ------------------------------------------------------------

fn media_type_from_parsed_kind(parsed: &ParsedFileInfo) -> MediaType {
    match parsed.kind {
        crate::release_parser::MediaKind::TvShow => MediaType::TvShow,
        crate::release_parser::MediaKind::Movie | crate::release_parser::MediaKind::Unknown => {
            MediaType::Movie
        }
    }
}

fn media_type_to_str(mt: MediaType) -> String {
    match mt {
        MediaType::Movie => "movie".into(),
        MediaType::TvShow => "tv_show".into(),
        MediaType::Book => "book".into(),
    }
}

fn provider_kind_str(pk: mydia_rs_metadata::ProviderKind) -> String {
    match pk {
        mydia_rs_metadata::ProviderKind::Tvdb => "tvdb".into(),
        _ => "tmdb".into(),
    }
}

fn provider_from_row(row: &mydia_rs_entities::media_items::Model) -> (String, String) {
    if let Some(tmdb_id) = row.tmdb_id {
        (tmdb_id.to_string(), "tmdb".into())
    } else if let Some(tvdb_id) = row.tvdb_id {
        (tvdb_id.to_string(), "tvdb".into())
    } else {
        (row.id.0.to_string(), "internal".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_strips_quality_and_year() {
        let result = normalize_search_query("The.Office.US.S01E01.1080p.BluRay.x264-GROUP");
        assert_eq!(result, "The Office US");
    }

    #[test]
    fn normalize_strips_bracketed_ids() {
        let result = normalize_search_query("[tvdb-81189] Breaking Bad");
        assert_eq!(result, "Breaking Bad");
    }

    #[test]
    fn normalize_empty_returns_empty() {
        assert_eq!(normalize_search_query(""), "");
    }

    #[test]
    fn similarity_identical_is_one() {
        assert!((title_similarity("Breaking Bad", "Breaking Bad") - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn similarity_case_insensitive() {
        assert!((title_similarity("BREAKING BAD", "breaking bad") - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn similarity_different_is_low() {
        let sim = title_similarity("Breaking Bad", "The Office");
        assert!(sim < 0.5, "similarity should be low: {sim}");
    }

    #[test]
    fn similarity_substring_is_moderate() {
        let sim = title_similarity("Breaking Bad", "Breaking");
        assert!(sim > 0.3 && sim < 0.8, "similarity: {sim}");
    }

    #[test]
    fn levenshtein_exact() {
        assert_eq!(levenshtein_distance("abc", "abc"), 0);
    }

    #[test]
    fn levenshtein_one_sub() {
        assert_eq!(levenshtein_distance("abc", "abd"), 1);
    }

    #[test]
    fn levenshtein_empty() {
        assert_eq!(levenshtein_distance("", "abc"), 3);
        assert_eq!(levenshtein_distance("abc", ""), 3);
    }
}
