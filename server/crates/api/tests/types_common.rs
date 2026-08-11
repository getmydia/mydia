//! Proves the common type group matches the reference contract. Only the
//! types this group owns are compared; the remaining groups arrive in later
//! tasks and full equality is asserted in tests/sdl_parity.rs.

use mydia_api::sdl::canonicalize;

/// The 17 types owned by this group: the Node interface, the pagination
/// machinery, the one shared input, and all 12 enums. Keep in sync with the
/// comment in src/types/common.rs.
const OWNED: &[&str] = &[
    "Node",
    "NodeEdge",
    "NodeConnection",
    "PageInfo",
    "SortInput",
    "DeviceEventType",
    "MediaType",
    "SearchResultType",
    "LibraryType",
    "SortField",
    "SortDirection",
    "MediaCategory",
    "SubtitleFormat",
    "StreamingStrategy",
    "StreamingCandidateStrategy",
    "SegmentType",
    "MediaStreamType",
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
    let ours = canonicalize(&mydia_api::types::common::sdl_fragment()).unwrap();

    for name in OWNED {
        let ours_line = line_for(&ours, name)
            .unwrap_or_else(|| panic!("{name} is not declared in the common group"));
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
