//! Table-driven release-parser integration tests.
//!
//! Each row carries an input filename and the expected `title`,
//! `year`, `season`, `episodes`, `quality.{resolution,source,codec}`,
//! and `release_group` values. The U16 port targets the canonical
//! Phoenix `release_parser_test.exs` cases plus a representative
//! slice of the V2/V3 corpus. Deeper corpus parity (anime fansubs,
//! Windows-path patterns, the long tail of resolver carve-outs) is
//! deferred — see `crates/library/src/release_parser/mod.rs` for
//! the scope-note.

use mydia_rs_library::release_parser::{MediaKind, ReleaseParser};

#[derive(Debug, Default)]
struct Expected {
    title: Option<&'static str>,
    year: Option<i32>,
    season: Option<i32>,
    episodes: Option<Vec<i32>>,
    resolution: Option<&'static str>,
    source: Option<&'static str>,
    codec: Option<&'static str>,
    release_group: Option<&'static str>,
    kind: Option<MediaKind>,
}

fn case(input: &str, expected: Expected) -> (String, Result<(), String>) {
    let result = ReleaseParser::parse(input);
    let mut failures = Vec::new();

    if let Some(t) = expected.title {
        if result.title.as_deref() != Some(t) {
            failures.push(format!("title: want {t:?} got {:?}", result.title));
        }
    }
    if let Some(y) = expected.year {
        if result.year != Some(y) {
            failures.push(format!("year: want {y:?} got {:?}", result.year));
        }
    }
    if let Some(s) = expected.season {
        if result.season != Some(s) {
            failures.push(format!("season: want {s:?} got {:?}", result.season));
        }
    }
    if let Some(eps) = expected.episodes {
        if result.episodes.as_deref() != Some(eps.as_slice()) {
            failures.push(format!(
                "episodes: want {:?} got {:?}",
                eps, result.episodes
            ));
        }
    }
    if let Some(r) = expected.resolution {
        if result.quality.resolution.as_deref() != Some(r) {
            failures.push(format!(
                "resolution: want {r:?} got {:?}",
                result.quality.resolution
            ));
        }
    }
    if let Some(s) = expected.source {
        if result.quality.source.as_deref() != Some(s) {
            failures.push(format!(
                "source: want {s:?} got {:?}",
                result.quality.source
            ));
        }
    }
    if let Some(c) = expected.codec {
        if result.quality.codec.as_deref() != Some(c) {
            failures.push(format!("codec: want {c:?} got {:?}", result.quality.codec));
        }
    }
    if let Some(g) = expected.release_group {
        if result.release_group.as_deref() != Some(g) {
            failures.push(format!("group: want {g:?} got {:?}", result.release_group));
        }
    }
    if let Some(k) = expected.kind {
        if result.kind != k {
            failures.push(format!("kind: want {k:?} got {:?}", result.kind));
        }
    }

    if failures.is_empty() {
        (input.to_owned(), Ok(()))
    } else {
        (input.to_owned(), Err(failures.join("; ")))
    }
}

fn run_cases(cases: Vec<(&'static str, Expected)>) {
    let total = cases.len();
    let mut passed: u32 = 0;
    let mut failures = Vec::new();
    for (input, expected) in cases {
        let (label, outcome) = case(input, expected);
        match outcome {
            Ok(()) => passed += 1,
            Err(reason) => failures.push(format!("{label}: {reason}")),
        }
    }

    let rate = f64::from(passed) / total as f64 * 100.0;
    println!("Release-parser pass rate: {passed}/{total} ({rate:.1}%)");
    for failure in &failures {
        println!("  FAIL: {failure}");
    }

    // Soft floor — the U16 port targets ≥80% on the canonical cases
    // and explicitly defers the long-tail corpus to a follow-up.
    // The 95% R10 target lives behind the Phoenix corpus; we'll lift
    // this floor as the parser matures.
    assert!(
        rate >= 80.0,
        "pass rate {rate:.1}% below 80% floor (passed {passed}/{total})"
    );
}

#[test]
fn movie_canonical_cases() {
    run_cases(vec![
        (
            "Movie.Name.2020.1080p.BluRay.x264-GROUP.mkv",
            Expected {
                title: Some("Movie Name"),
                year: Some(2020),
                resolution: Some("1080p"),
                source: Some("BluRay"),
                codec: Some("x264"),
                release_group: Some("GROUP"),
                kind: Some(MediaKind::Movie),
                ..Expected::default()
            },
        ),
        (
            "The.Matrix.1999.2160p.UHD.BluRay.x265-RELEASE.mkv",
            Expected {
                title: Some("The Matrix"),
                year: Some(1999),
                resolution: Some("2160p"),
                source: Some("BluRay"),
                codec: Some("x265"),
                release_group: Some("RELEASE"),
                kind: Some(MediaKind::Movie),
                ..Expected::default()
            },
        ),
        (
            "Inception.2010.1080p.BluRay.x264.mkv",
            Expected {
                title: Some("Inception"),
                year: Some(2010),
                resolution: Some("1080p"),
                source: Some("BluRay"),
                codec: Some("x264"),
                kind: Some(MediaKind::Movie),
                ..Expected::default()
            },
        ),
        (
            "Some.Movie.2018.720p.WEB-DL.x264-GRP.mkv",
            Expected {
                title: Some("Some Movie"),
                year: Some(2018),
                resolution: Some("720p"),
                source: Some("WEB-DL"),
                codec: Some("x264"),
                release_group: Some("GRP"),
                kind: Some(MediaKind::Movie),
                ..Expected::default()
            },
        ),
    ]);
}

#[test]
fn tv_show_canonical_cases() {
    run_cases(vec![
        (
            "Show.Name.S01E05.1080p.WEB-DL.mkv",
            Expected {
                title: Some("Show Name"),
                season: Some(1),
                episodes: Some(vec![5]),
                resolution: Some("1080p"),
                source: Some("WEB-DL"),
                kind: Some(MediaKind::TvShow),
                ..Expected::default()
            },
        ),
        (
            "Severance.S02E04.1080p.WEB-DL.mkv",
            Expected {
                title: Some("Severance"),
                season: Some(2),
                episodes: Some(vec![4]),
                resolution: Some("1080p"),
                source: Some("WEB-DL"),
                kind: Some(MediaKind::TvShow),
                ..Expected::default()
            },
        ),
        (
            "Show.Name.S01E01-E03.720p.HDTV.x264.mkv",
            Expected {
                title: Some("Show Name"),
                season: Some(1),
                episodes: Some(vec![1, 2, 3]),
                resolution: Some("720p"),
                source: Some("HDTV"),
                codec: Some("x264"),
                kind: Some(MediaKind::TvShow),
                ..Expected::default()
            },
        ),
    ]);
}

#[test]
fn edge_cases() {
    let r = ReleaseParser::parse("");
    assert_eq!(r.kind, MediaKind::Unknown);
    assert!(r.confidence.abs() < f64::EPSILON);

    let r = ReleaseParser::parse(".mkv");
    assert_eq!(r.kind, MediaKind::Unknown);

    // Full-path input still uses the basename for parsing.
    let r = ReleaseParser::parse("/media/movies/Movie Title (2020) 1080p.mkv");
    assert_eq!(r.year, Some(2020));

    // Random filename returns empty quality.
    let r = ReleaseParser::parse("randomfile.mkv");
    assert!(r.quality.empty());
}

#[test]
fn quality_field_extraction() {
    let r = ReleaseParser::parse("Movie.2020.1080p.BluRay.x264.DDP5.1.mkv");
    assert_eq!(r.quality.resolution.as_deref(), Some("1080p"));
    assert_eq!(r.quality.source.as_deref(), Some("BluRay"));
    assert_eq!(r.quality.codec.as_deref(), Some("x264"));
    // Audio is parsed; the exact canonical form (DDP5.1 vs "Dolby Digital Plus 5.1") is
    // controlled by an option that the port currently leaves at the
    // default ("raw token") mode.
    assert!(r.quality.audio.is_some());
}

#[test]
fn release_group_detection() {
    let r = ReleaseParser::parse("Movie.Name.2020.1080p.BluRay.x264-RELEASE.mkv");
    assert_eq!(r.release_group.as_deref(), Some("RELEASE"));

    // Compound suffixes should NOT be treated as release groups.
    let r = ReleaseParser::parse("Movie.2020.1080p.AAC-LC.x264.mkv");
    assert_ne!(r.release_group.as_deref(), Some("LC"));
}
