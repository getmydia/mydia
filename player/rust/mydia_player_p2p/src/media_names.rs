//! Filename parsing and TMDB match scoring for the files library, exposed to
//! Dart. The logic lives in `mydia_media_names`, shared with the server; this
//! module only maps its types onto FFI-friendly ones.

use flutter_rust_bridge::frb;
use mydia_media_names::names::identity_key;
use mydia_media_names::parser::{parse, LibraryKind, ParsedKind};
use mydia_media_names::score::{score, Candidate, Wanted};
use std::path::Path;

pub enum FfiKind {
    Movies,
    Series,
    Mixed,
}

pub struct FfiParsed {
    pub path: String,
    pub is_episode: bool,
    pub title: String,
    pub year: Option<i32>,
    pub season: Option<i32>,
    pub episode: Option<i32>,
    pub episode_end: Option<i32>,
    /// Files that describe the same movie or show share a key.
    pub group_key: String,
}

pub struct FfiCandidate {
    pub id: i64,
    pub title: String,
    pub original_title: Option<String>,
    pub year: Option<i32>,
}

pub struct FfiMatch {
    pub id: i64,
    pub confidence: f64,
}

impl From<FfiKind> for LibraryKind {
    fn from(kind: FfiKind) -> Self {
        match kind {
            FfiKind::Movies => Self::Movies,
            FfiKind::Series => Self::Series,
            FfiKind::Mixed => Self::Mixed,
        }
    }
}

/// Parses each path under `root`. Paths that do not parse are omitted.
#[frb(sync)]
pub fn parse_batch(root: String, paths: Vec<String>, kind: FfiKind) -> Vec<FfiParsed> {
    let kind = LibraryKind::from(kind);
    let root = Path::new(&root);
    paths
        .into_iter()
        .filter_map(|path| {
            let parsed = parse(Path::new(&path), root, kind)?;
            let key = identity_key(&parsed.title);
            let (is_episode, season, episode, episode_end, group_key) = match parsed.kind {
                ParsedKind::Movie => (
                    false,
                    None,
                    None,
                    None,
                    format!(
                        "{key}|{}",
                        parsed.year.map(|y| y.to_string()).unwrap_or_default()
                    ),
                ),
                ParsedKind::Episode {
                    season,
                    episode,
                    episode_end,
                } => (true, Some(season), Some(episode), episode_end, key),
            };
            Some(FfiParsed {
                path,
                is_episode,
                title: parsed.title,
                year: parsed.year,
                season,
                episode,
                episode_end,
                group_key,
            })
        })
        .collect()
}

/// Picks the candidate that best matches the wanted title, or None when no
/// candidate is confident enough.
#[frb(sync)]
pub fn score_candidates(
    title: String,
    year: Option<i32>,
    is_show: bool,
    candidates: Vec<FfiCandidate>,
) -> Option<FfiMatch> {
    let wanted = Wanted {
        title,
        year,
        is_show,
    };
    let candidates: Vec<Candidate> = candidates
        .into_iter()
        .map(|c| Candidate {
            id: c.id,
            title: c.title,
            original_title: c.original_title,
            year: c.year,
        })
        .collect();
    score(&wanted, &candidates).map(|m| FfiMatch {
        id: m.id,
        confidence: m.confidence,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_batch_keeps_parsable_paths() {
        let out = parse_batch(
            "/lib".to_string(),
            vec![
                "/lib/Copper Valley (2018)/Copper Valley (2018).mkv".to_string(),
                "/lib/1080p.mkv".to_string(),
            ],
            FfiKind::Mixed,
        );
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].title, "Copper Valley");
        assert_eq!(out[0].year, Some(2018));
        assert_eq!(out[0].group_key, "coppervalley|2018");
    }
}
