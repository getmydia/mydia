//! Proves the media type group matches the reference contract.

use mydia_api::sdl::canonicalize;

/// The 17 types owned by this group. Keep in sync with the comment in
/// src/types/media.rs.
const OWNED: &[&str] = &[
    "Movie",
    "TvShow",
    "Season",
    "Episode",
    "ShowNextUp",
    "MovieEdge",
    "MovieConnection",
    "TvShowEdge",
    "TvShowConnection",
    "Artwork",
    "CastMember",
    "MediaFile",
    "MediaSegment",
    "Progress",
    "LibraryPath",
    "RecentlyAddedItem",
    "SubtitleTrack",
];

fn reference_sdl() -> String {
    std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../player/lib/graphql/schema.graphql"
    ))
    .expect("reference schema not found")
}

#[test]
fn owned_types_match_the_reference() {
    let reference = canonicalize(&reference_sdl()).unwrap();
    let ours = canonicalize(&mydia_api::types::media::sdl_fragment()).unwrap();

    for name in OWNED {
        let ours_line = line_for(&ours, name)
            .unwrap_or_else(|| panic!("{name} is not declared in the media group"));
        let reference_line = line_for(&reference, name)
            .unwrap_or_else(|| panic!("{name} is not in the reference SDL"));

        assert_eq!(
            ours_line, reference_line,
            "{name} differs from the contract"
        );
    }
}

fn line_for(canonical: &str, name: &str) -> Option<String> {
    canonical
        .lines()
        .find(|line| {
            line.split_whitespace()
                .nth(1)
                .map(|n| n.trim_end_matches(['{', '(']))
                == Some(name)
        })
        .map(str::to_owned)
}
