//! Two tiers of parser measurement.
//!
//! Tier A is a hard gate over the naming conventions Mydia Server actually
//! meets. Tier B is a ratchet over the harvested Radarr and Sonarr corpora:
//! the number of passing cases may rise and must never fall.

use std::path::Path;

use mydia_library::parser::{parse, LibraryKind, ParsedKind};
use serde::Deserialize;

/// A Tier A case: a path relative to the library root, the library kind, and
/// what the parser must produce.
struct Case {
    relative: &'static str,
    kind: LibraryKind,
    title: &'static str,
    year: Option<i32>,
    /// None for a movie, Some((season, episode, episode_end)) otherwise.
    episode: Option<(i32, i32, Option<i32>)>,
}

const TIER_A: &[Case] = &[
    Case {
        relative: "The Matrix (1999)/The Matrix (1999).mkv",
        kind: LibraryKind::Movies,
        title: "The Matrix",
        year: Some(1999),
        episode: None,
    },
    Case {
        relative: "The Matrix (1999)/The Matrix (1999) - 2160p.mkv",
        kind: LibraryKind::Movies,
        title: "The Matrix",
        year: Some(1999),
        episode: None,
    },
    Case {
        relative: "Blade Runner 2049 (2017)/Blade Runner 2049 (2017).mkv",
        kind: LibraryKind::Movies,
        title: "Blade Runner 2049",
        year: Some(2017),
        episode: None,
    },
    Case {
        relative: "Movie.Title.2020.2160p.BluRay.x265-GROUP.mkv",
        kind: LibraryKind::Movies,
        title: "Movie Title",
        year: Some(2020),
        episode: None,
    },
    Case {
        relative: "Movie_Title_2020_1080p.mkv",
        kind: LibraryKind::Movies,
        title: "Movie Title",
        year: Some(2020),
        episode: None,
    },
    Case {
        relative: "2012 (2009)/2012 (2009).mkv",
        kind: LibraryKind::Movies,
        title: "2012",
        year: Some(2009),
        episode: None,
    },
    Case {
        relative: "Amelie (2001)/Amelie (2001) {edition-Directors Cut}.mkv",
        kind: LibraryKind::Movies,
        title: "Amelie",
        year: Some(2001),
        episode: None,
    },
    Case {
        relative: "Untitled Short/Untitled Short.mkv",
        kind: LibraryKind::Movies,
        title: "Untitled Short",
        year: None,
        episode: None,
    },
    Case {
        relative: "Show Name/Season 01/Show Name - S01E01 - Pilot.mkv",
        kind: LibraryKind::Series,
        title: "Show Name",
        year: None,
        episode: Some((1, 1, None)),
    },
    Case {
        relative: "Show Name (2015)/Season 01/Show Name - S01E01 - Pilot.mkv",
        kind: LibraryKind::Series,
        title: "Show Name",
        year: Some(2015),
        episode: Some((1, 1, None)),
    },
    Case {
        relative: "Show.Name.S02E10.1080p.WEB-DL.x264-GROUP.mkv",
        kind: LibraryKind::Series,
        title: "Show Name",
        year: None,
        episode: Some((2, 10, None)),
    },
    Case {
        relative: "Show.Name.S01E02E03.1080p.mkv",
        kind: LibraryKind::Series,
        title: "Show Name",
        year: None,
        episode: Some((1, 2, Some(3))),
    },
    Case {
        relative: "Show Name/Season 3/Show Name - 3x07 - Title.mkv",
        kind: LibraryKind::Series,
        title: "Show Name",
        year: None,
        episode: Some((3, 7, None)),
    },
    Case {
        relative: "Show Name/Specials/Show Name - S00E02 - Christmas.mkv",
        kind: LibraryKind::Series,
        title: "Show Name",
        year: None,
        episode: Some((0, 2, None)),
    },
    Case {
        relative: "Show Name/Season 02/02 - Title.mkv",
        kind: LibraryKind::Series,
        title: "Show Name",
        year: None,
        episode: Some((2, 2, None)),
    },
    Case {
        relative: "Show Name/Season 01/S01E04.mkv",
        kind: LibraryKind::Series,
        title: "Show Name",
        year: None,
        episode: Some((1, 4, None)),
    },
    Case {
        relative: "Anime Show/[SubsPlease] Anime Show - 12 (1080p) [ABCD1234].mkv",
        kind: LibraryKind::Series,
        title: "Anime Show",
        year: None,
        episode: Some((1, 12, None)),
    },
    Case {
        relative: "Anime Show/[SubsPlease] Anime Show - 12v2 (1080p).mkv",
        kind: LibraryKind::Series,
        title: "Anime Show",
        year: None,
        episode: Some((1, 12, None)),
    },
    Case {
        relative: "Mixed/Show.Name.S01E02.mkv",
        kind: LibraryKind::Mixed,
        title: "Show Name",
        year: None,
        episode: Some((1, 2, None)),
    },
    Case {
        relative: "Mixed/Movie.Title.2020.mkv",
        kind: LibraryKind::Mixed,
        title: "Movie Title",
        year: Some(2020),
        episode: None,
    },
];

#[test]
fn tier_a_conventions_all_parse() {
    let root = Path::new("/library");
    let mut failures = Vec::new();

    for case in TIER_A {
        let Some(parsed) = parse(&root.join(case.relative), root, case.kind) else {
            failures.push(format!("{}: parsed to None", case.relative));
            continue;
        };

        if parsed.title != case.title {
            failures.push(format!(
                "{}: title was {:?}, wanted {:?}",
                case.relative, parsed.title, case.title
            ));
        }

        if parsed.year != case.year {
            failures.push(format!(
                "{}: year was {:?}, wanted {:?}",
                case.relative, parsed.year, case.year
            ));
        }

        let actual = match parsed.kind {
            ParsedKind::Movie => None,
            ParsedKind::Episode {
                season,
                episode,
                episode_end,
            } => Some((season, episode, episode_end)),
        };

        if actual != case.episode {
            failures.push(format!(
                "{}: numbering was {:?}, wanted {:?}",
                case.relative, actual, case.episode
            ));
        }
    }

    assert!(
        failures.is_empty(),
        "Tier A failures:\n{}",
        failures.join("\n")
    );
}

#[derive(Debug, Deserialize)]
struct CorpusCase {
    input: String,
    expected: Expected,
    elixir_passes: bool,
}

#[derive(Debug, Deserialize)]
struct Expected {
    title: Option<String>,
    year: Option<i32>,
    season: Option<i32>,
    episode: Option<i32>,
}

fn normalize(value: &str) -> String {
    value
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

/// Raise this only by running the test and copying the reported number. Never
/// lower it: a drop means a parser change lost ground the corpus had gained.
const TIER_B_FLOOR: usize = 232;

#[test]
fn tier_b_corpus_pass_count_does_not_regress() {
    let raw = include_str!("fixtures/parser_corpus.json");
    let cases: Vec<CorpusCase> = serde_json::from_str(raw).expect("the corpus fixture parses");

    let root = Path::new("/library");
    let mut passed = 0usize;
    let mut elixir_only = Vec::new();

    for case in &cases {
        // The corpus holds bare release names, not paths, and covers both
        // movies and series, so Mixed is the only honest library kind here.
        let path = root.join(format!("{}.mkv", case.input));
        let parsed = parse(&path, root, LibraryKind::Mixed);

        let ok = match &parsed {
            None => false,
            Some(parsed) => {
                let title_ok = case
                    .expected
                    .title
                    .as_ref()
                    .map(|want| normalize(&parsed.title) == normalize(want))
                    .unwrap_or(true);

                let year_ok = case
                    .expected
                    .year
                    .map(|want| parsed.year == Some(want))
                    .unwrap_or(true);

                let (season, episode) = match parsed.kind {
                    ParsedKind::Movie => (None, None),
                    ParsedKind::Episode {
                        season, episode, ..
                    } => (Some(season), Some(episode)),
                };

                let season_ok = case
                    .expected
                    .season
                    .map(|want| season == Some(want))
                    .unwrap_or(true);
                let episode_ok = case
                    .expected
                    .episode
                    .map(|want| episode == Some(want))
                    .unwrap_or(true);

                title_ok && year_ok && season_ok && episode_ok
            }
        };

        if ok {
            passed += 1;
        } else if case.elixir_passes {
            elixir_only.push(case.input.as_str());
        }
    }

    let elixir_passing = cases.iter().filter(|c| c.elixir_passes).count();

    println!(
        "Tier B: {passed} of {} cases pass ({elixir_passing} pass in Elixir). \
         {} cases pass in Elixir but not here.",
        cases.len(),
        elixir_only.len()
    );

    assert!(
        passed >= TIER_B_FLOOR,
        "the corpus pass count fell from {TIER_B_FLOOR} to {passed}"
    );
}
