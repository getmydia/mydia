use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;

use crate::names::{clean_title, plausible_year};

/// What the operator told us this directory holds. A strong prior: a movies
/// library never yields an episode however the file is named, which keeps
/// "Blade Runner 2049" out of season 20.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LibraryKind {
    Movies,
    Series,
    Mixed,
}

impl LibraryKind {
    #[allow(clippy::should_implement_trait)]
    pub fn from_str(value: &str) -> Option<Self> {
        match value {
            "movies" => Some(Self::Movies),
            "series" => Some(Self::Series),
            "mixed" => Some(Self::Mixed),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParsedKind {
    Movie,
    Episode {
        season: i32,
        episode: i32,
        /// The last episode of a multi-episode file, when the name declares a
        /// range such as S01E02E03.
        episode_end: Option<i32>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedFile {
    pub kind: ParsedKind,
    pub title: String,
    pub year: Option<i32>,
}

/// A year in parentheses or brackets, or as a standalone separated token.
static YEAR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[\(\[\s._-](\d{4})[\)\]\s._-]?").expect("static pattern"));

/// Parses one file into an item description, or returns None when nothing
/// usable is there. None is not a failure of the file: the caller records a
/// scan issue and carries on.
pub fn parse(path: &Path, root: &Path, kind: LibraryKind) -> Option<ParsedFile> {
    let stem = path.file_stem()?.to_str()?;

    if kind != LibraryKind::Movies {
        if let Some(parsed) = episode::parse(path, root, stem) {
            return Some(parsed);
        }

        if kind == LibraryKind::Series {
            return None;
        }
    }

    parse_movie(path, root, stem)
}

fn parse_movie(path: &Path, root: &Path, stem: &str) -> Option<ParsedFile> {
    let from_stem = title_and_year(stem);

    // A stem with its own year wins outright: "The Matrix (1999).mkv".
    if let Some((title, Some(year))) = &from_stem {
        return Some(ParsedFile {
            kind: ParsedKind::Movie,
            title: title.clone(),
            year: Some(*year),
        });
    }

    // A generic filename ("movie.mkv") inside a named, dated folder borrows
    // the folder's title and year rather than keeping "movie" as the title.
    if let Some(folder) = enclosing_folder(path, root) {
        if let Some((title, year)) = title_and_year(&folder) {
            return Some(ParsedFile {
                kind: ParsedKind::Movie,
                title,
                year,
            });
        }
    }

    from_stem.map(|(title, year)| ParsedFile {
        kind: ParsedKind::Movie,
        title,
        year,
    })
}

/// Splits a name into its title and its year. Returns None when nothing
/// survives as a title, so the caller can fall back to the folder name.
fn title_and_year(name: &str) -> Option<(String, Option<i32>)> {
    if let Some((start, year)) = last_year_match(name) {
        let title = clean_title(&name[..start]);

        if !title.is_empty() && !is_only_quality_tokens(&title) {
            return Some((title, Some(year)));
        }
    }

    let trimmed = match quality_cutoff(name) {
        Some(cut) => &name[..cut],
        None => name,
    };
    let title = clean_title(trimmed);

    if title.is_empty() || is_only_quality_tokens(&title) {
        return None;
    }

    Some((title, None))
}

/// The last plausible year in the name, with the byte offset where it starts.
///
/// Last rather than first, so "2012 (2009)" keeps 2012 as the title and reads
/// 2009 as the year. A year at offset 0 is rejected, since it would leave no
/// title in front of it.
fn last_year_match(name: &str) -> Option<(usize, i32)> {
    let mut best: Option<(usize, i32)> = None;

    for capture in YEAR.captures_iter(name) {
        let Some(whole) = capture.get(0) else {
            continue;
        };

        let Some(group) = capture.get(1) else {
            continue;
        };

        let Ok(value) = group.as_str().parse::<i32>() else {
            continue;
        };

        if plausible_year(value) {
            best = Some((whole.start(), value));
        }
    }

    best.filter(|(start, _)| *start > 0)
}

/// Leading quality tokens, matched one at a time so a run of them can be
/// consumed. "1080p BluRay" is not a title; "Blade Runner" is.
static QUALITY_TOKEN: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)^(\d{3,4}p|4k|uhd|hdr\d*|bluray|blu-ray|web-?dl|webrip|hdtv|dvdrip|remux|x26[45]|h\.?26[45]|hevc|avc|aac|dts|proper|repack)([\s._-]+|$)",
    )
    .expect("static pattern")
});

fn is_only_quality_tokens(title: &str) -> bool {
    let mut rest = title;

    while let Some(matched) = QUALITY_TOKEN.find(rest) {
        rest = &rest[matched.end()..];
    }

    rest.trim().is_empty()
}

/// A quality/encoding token anywhere in the name, delimited by the usual
/// scene-release separators. Marks the start of release metadata, so a
/// year-less scene name like "Movie.Title.1080p.BluRay" keeps "Movie Title"
/// and drops everything from "1080p" onward.
static QUALITY_CUT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)(?:^|[\s._-])(\d{3,4}p|4k|uhd|hdr\d*|bluray|blu-ray|web-?dl|webrip|hdtv|dvdrip|remux|x26[45]|h\.?26[45]|hevc|avc|aac|dts|proper|repack)(?:[\s._-]|$)",
    )
    .expect("static pattern")
});

fn quality_cutoff(name: &str) -> Option<usize> {
    QUALITY_CUT.find(name).map(|m| m.start())
}

/// The directory containing `path`, unless that directory is the library root
/// itself, in which case there is no folder context to borrow from.
fn enclosing_folder(path: &Path, root: &Path) -> Option<String> {
    let parent = path.parent()?;

    if parent == root {
        return None;
    }

    Some(parent.file_name()?.to_str()?.to_string())
}

mod episode;

#[cfg(test)]
mod tests {
    use super::{parse, LibraryKind, ParsedFile, ParsedKind};
    use std::path::Path;

    fn movie(relative: &str) -> ParsedFile {
        let root = Path::new("/media/movies");
        parse(&root.join(relative), root, LibraryKind::Movies)
            .unwrap_or_else(|| panic!("failed to parse {relative}"))
    }

    #[test]
    fn a_plex_style_movie_parses() {
        let parsed = movie("The Matrix (1999)/The Matrix (1999).mkv");

        assert!(matches!(parsed.kind, ParsedKind::Movie));
        assert_eq!(parsed.title, "The Matrix");
        assert_eq!(parsed.year, Some(1999));
    }

    #[test]
    fn a_scene_movie_parses() {
        let parsed = movie("Movie.Title.2020.2160p.BluRay.x265-GROUP.mkv");

        assert_eq!(parsed.title, "Movie Title");
        assert_eq!(parsed.year, Some(2020));
    }

    #[test]
    fn an_edition_suffix_is_dropped() {
        let parsed = movie("The Matrix (1999) {edition-Directors Cut}.mkv");

        assert_eq!(parsed.title, "The Matrix");
        assert_eq!(parsed.year, Some(1999));
    }

    #[test]
    fn a_year_in_the_folder_rescues_a_year_less_filename() {
        let parsed = movie("The Matrix (1999)/movie.mkv");

        assert_eq!(parsed.title, "The Matrix");
        assert_eq!(parsed.year, Some(1999));
    }

    #[test]
    fn a_numeric_title_is_not_eaten_by_its_own_year() {
        let parsed = movie("2012 (2009).mkv");

        assert_eq!(parsed.title, "2012");
        assert_eq!(parsed.year, Some(2009));
    }

    #[test]
    fn a_movie_without_a_year_still_parses() {
        let parsed = movie("Some Movie.mkv");

        assert_eq!(parsed.title, "Some Movie");
        assert_eq!(parsed.year, None);
    }

    #[test]
    fn a_resolution_is_not_mistaken_for_a_year() {
        let parsed = movie("Movie.Title.1080p.BluRay.mkv");

        assert_eq!(parsed.title, "Movie Title");
        assert_eq!(parsed.year, None);
    }

    #[test]
    fn a_file_with_no_usable_title_is_none() {
        let root = Path::new("/media/movies");

        assert!(parse(&root.join("1080p.mkv"), root, LibraryKind::Movies).is_none());
    }

    #[test]
    fn a_movie_library_never_produces_an_episode() {
        let parsed = movie("Show.Name.S01E02.mkv");

        assert!(matches!(parsed.kind, ParsedKind::Movie));
    }
}
