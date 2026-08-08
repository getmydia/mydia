use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;

use crate::names::{clean_title, plausible_year};
use crate::parser::{ParsedFile, ParsedKind};

/// S01E02, S01E02E03, S01.E02, s1e2.
static SXXEYY: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\bs(\d{1,3})[\s._-]*e(\d{1,4})(?:[\s._-]*e(\d{1,4}))?\b")
        .expect("static pattern")
});

/// Season 2 Episode 5. Tried before the cross form, whose pattern is looser.
static SPELLED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\bseason[\s._-]*(\d{1,3})[\s._-]*episode[\s._-]*(\d{1,4})\b")
        .expect("static pattern")
});

/// 1x02.
static CROSS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\b(\d{1,2})x(\d{1,3})\b").expect("static pattern"));

/// A leading episode number in a season folder: "02 - Title.mkv".
static LEADING_NUMBER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(\d{1,3})(?:[\s._-]|$)").expect("static pattern"));

/// "[Group] Show Name - 12 (1080p)" and "[Group] Show Name - 12v2".
static ABSOLUTE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^\[[^\]]+\]\s*(?P<title>.+?)\s*-\s*(?P<episode>\d{1,4})(?:v\d+)?\b")
        .expect("static pattern")
});

/// "Season 01", "Season 1", "S01", "Series 2".
static SEASON_FOLDER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(?:season|series|s)[\s._-]*(\d{1,3})$").expect("static pattern")
});

/// A year, for splitting "Show Name (2015)".
static YEAR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[\(\[\s._-](\d{4})[\)\]\s._-]?").expect("static pattern"));

pub fn parse(path: &Path, root: &Path, stem: &str) -> Option<ParsedFile> {
    let found = from_filename(stem).or_else(|| from_season_folder(path, root, stem))?;

    // A title from the filename wins; otherwise the show folder names it.
    let raw_title = if found.title.is_empty() {
        show_folder_name(path, root)?
    } else {
        found.title
    };

    // A show's year lives on its folder, not on the episode file, so the
    // folder is consulted whenever the filename carried none.
    let (title, year) = match split_year(&raw_title) {
        Some((title, Some(year))) => (title, Some(year)),
        Some((title, None)) => {
            let year = show_folder_name(path, root)
                .and_then(|folder| split_year(&folder))
                .and_then(|(_, year)| year);

            (title, year)
        }
        None => return None,
    };

    Some(ParsedFile {
        kind: ParsedKind::Episode {
            season: found.season,
            episode: found.episode,
            episode_end: found.episode_end,
        },
        title,
        year,
    })
}

struct Found {
    title: String,
    season: i32,
    episode: i32,
    episode_end: Option<i32>,
}

fn from_filename(stem: &str) -> Option<Found> {
    if let Some(caps) = SXXEYY.captures(stem) {
        let whole = caps.get(0)?;

        return Some(Found {
            title: clean_title(&stem[..whole.start()]),
            season: caps.get(1)?.as_str().parse().ok()?,
            episode: caps.get(2)?.as_str().parse().ok()?,
            episode_end: caps.get(3).and_then(|m| m.as_str().parse().ok()),
        });
    }

    if let Some(caps) = SPELLED.captures(stem) {
        let whole = caps.get(0)?;

        return Some(Found {
            title: clean_title(&stem[..whole.start()]),
            season: caps.get(1)?.as_str().parse().ok()?,
            episode: caps.get(2)?.as_str().parse().ok()?,
            episode_end: None,
        });
    }

    if let Some(caps) = CROSS.captures(stem) {
        let whole = caps.get(0)?;

        return Some(Found {
            title: clean_title(&stem[..whole.start()]),
            season: caps.get(1)?.as_str().parse().ok()?,
            episode: caps.get(2)?.as_str().parse().ok()?,
            episode_end: None,
        });
    }

    // Absolute numbering, which anime releases use. Guarded by the bracketed
    // group prefix and by rejecting anything that reads as a year, so
    // "Some Documentary - 2019" does not become episode 2019 of anything.
    if let Some(caps) = ABSOLUTE.captures(stem) {
        let episode: i32 = caps.name("episode")?.as_str().parse().ok()?;

        if !plausible_year(episode) {
            return Some(Found {
                title: clean_title(caps.name("title")?.as_str()),
                season: 1,
                episode,
                episode_end: None,
            });
        }
    }

    None
}

/// "Show Name/Season 2/02 - Title.mkv": the season comes from the folder and
/// the episode from a leading number.
fn from_season_folder(path: &Path, root: &Path, stem: &str) -> Option<Found> {
    let season = season_from_folder(path, root)?;
    let caps = LEADING_NUMBER.captures(stem)?;

    Some(Found {
        title: String::new(),
        season,
        episode: caps.get(1)?.as_str().parse().ok()?,
        episode_end: None,
    })
}

fn season_from_folder(path: &Path, root: &Path) -> Option<i32> {
    let parent = path.parent()?;

    if parent == root {
        return None;
    }

    let name = parent.file_name()?.to_str()?;

    if name.eq_ignore_ascii_case("specials") {
        return Some(0);
    }

    SEASON_FOLDER.captures(name)?.get(1)?.as_str().parse().ok()
}

/// The folder that names the show: the file's parent, or its grandparent when
/// the parent is a season folder.
fn show_folder_name(path: &Path, root: &Path) -> Option<String> {
    let parent = path.parent()?;

    if parent == root {
        return None;
    }

    let parent_name = parent.file_name()?.to_str()?;
    let is_season_folder =
        parent_name.eq_ignore_ascii_case("specials") || SEASON_FOLDER.is_match(parent_name);

    if !is_season_folder {
        return Some(parent_name.to_string());
    }

    let grandparent = parent.parent()?;

    if grandparent == root {
        return None;
    }

    Some(grandparent.file_name()?.to_str()?.to_string())
}

/// Splits "Show Name (2015)" into its title and year. Returns None only when
/// no title survives.
fn split_year(raw: &str) -> Option<(String, Option<i32>)> {
    if let Some(caps) = YEAR.captures_iter(raw).last() {
        if let Some(group) = caps.get(1) {
            if let Ok(value) = group.as_str().parse::<i32>() {
                if plausible_year(value) && group.start() > 0 {
                    let title = clean_title(&raw[..group.start()]);

                    if !title.is_empty() {
                        return Some((title, Some(value)));
                    }
                }
            }
        }
    }

    let title = clean_title(raw);

    if title.is_empty() {
        None
    } else {
        Some((title, None))
    }
}

#[cfg(test)]
mod tests {
    use crate::parser::{parse, LibraryKind, ParsedFile, ParsedKind};
    use std::path::Path;

    fn series(relative: &str) -> ParsedFile {
        let root = Path::new("/media/tv");
        parse(&root.join(relative), root, LibraryKind::Series)
            .unwrap_or_else(|| panic!("failed to parse {relative}"))
    }

    fn numbers(parsed: &ParsedFile) -> (i32, i32, Option<i32>) {
        match parsed.kind {
            ParsedKind::Episode {
                season,
                episode,
                episode_end,
            } => (season, episode, episode_end),
            ParsedKind::Movie => panic!("expected an episode, got a movie"),
        }
    }

    #[test]
    fn a_jellyfin_style_episode_parses() {
        let parsed = series("Show Name/Season 01/Show Name - S01E02 - Episode Title.mkv");

        assert_eq!(parsed.title, "Show Name");
        assert_eq!(numbers(&parsed), (1, 2, None));
    }

    #[test]
    fn a_scene_episode_parses() {
        let parsed = series("Show.Name.S01E02.1080p.WEB-DL.x264-GROUP.mkv");

        assert_eq!(parsed.title, "Show Name");
        assert_eq!(numbers(&parsed), (1, 2, None));
    }

    #[test]
    fn a_multi_episode_file_records_its_range() {
        let parsed = series("Show.Name.S01E02E03.mkv");

        assert_eq!(numbers(&parsed), (1, 2, Some(3)));
    }

    #[test]
    fn the_cross_form_parses() {
        let parsed = series("Show Name - 1x02 - Title.mkv");

        assert_eq!(parsed.title, "Show Name");
        assert_eq!(numbers(&parsed), (1, 2, None));
    }

    #[test]
    fn the_spelled_out_form_parses() {
        let parsed = series("Show Name Season 2 Episode 5.mkv");

        assert_eq!(parsed.title, "Show Name");
        assert_eq!(numbers(&parsed), (2, 5, None));
    }

    #[test]
    fn a_season_folder_supplies_a_missing_season() {
        let parsed = series("Show Name/Season 2/02 - Title.mkv");

        assert_eq!(parsed.title, "Show Name");
        assert_eq!(numbers(&parsed), (2, 2, None));
    }

    #[test]
    fn a_specials_folder_is_season_zero() {
        let parsed = series("Show Name/Specials/Show Name - S00E01.mkv");

        assert_eq!(numbers(&parsed), (0, 1, None));
    }

    #[test]
    fn a_show_folder_supplies_a_missing_title() {
        let parsed = series("Show Name/Season 01/S01E02.mkv");

        assert_eq!(parsed.title, "Show Name");
        assert_eq!(numbers(&parsed), (1, 2, None));
    }

    #[test]
    fn a_show_year_is_kept() {
        let parsed = series("Show Name (2015)/Season 01/Show Name - S01E01.mkv");

        assert_eq!(parsed.title, "Show Name");
        assert_eq!(parsed.year, Some(2015));
        assert_eq!(numbers(&parsed), (1, 1, None));
    }

    #[test]
    fn an_absolute_numbered_anime_episode_parses_as_season_one() {
        let parsed = series("[SubsPlease] Show Name - 12 (1080p) [ABCD1234].mkv");

        assert_eq!(parsed.title, "Show Name");
        assert_eq!(numbers(&parsed), (1, 12, None));
    }

    #[test]
    fn a_version_suffix_does_not_become_the_episode() {
        let parsed = series("[SubsPlease] Show Name - 12v2 (1080p).mkv");

        assert_eq!(numbers(&parsed), (1, 12, None));
    }

    #[test]
    fn a_year_after_a_dash_is_not_an_absolute_episode() {
        let root = Path::new("/media/tv");
        let parsed = parse(
            &root.join("[Group] Some Documentary - 2019.mkv"),
            root,
            LibraryKind::Series,
        );

        assert!(parsed.is_none(), "a bare year must not become episode 2019");
    }

    #[test]
    fn a_file_with_no_episode_marker_in_a_series_library_is_none() {
        let root = Path::new("/media/tv");

        assert!(parse(&root.join("Show Name/extra.mkv"), root, LibraryKind::Series).is_none());
    }

    #[test]
    fn a_mixed_library_still_parses_episodes() {
        let root = Path::new("/media/mixed");
        let parsed = parse(&root.join("Show.Name.S01E02.mkv"), root, LibraryKind::Mixed).unwrap();

        assert_eq!(numbers(&parsed), (1, 2, None));
    }
}
