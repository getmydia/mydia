//! Proves the auth, streaming and discovery type groups match the contract.

use mydia_api::sdl::canonicalize;

const OWNED_AUTH: &[&str] = &[
    "User",
    "LoginResult",
    "LoginInput",
    "AccessToken",
    "MediaToken",
    "ApiKey",
    "CreateApiKeyResult",
    "RemoteDevice",
    "RevokeDeviceResult",
    "ClaimCode",
    "Device",
    "DeviceStatusEvent",
    "ToggleFavoriteResult",
];

const OWNED_STREAMING: &[&str] = &[
    "StreamingCandidatesResult",
    "StreamingCandidate",
    "StreamingMetadata",
    "StreamingSessionResult",
    "DownloadOption",
    "PrepareDownloadResult",
    "DownloadJobStatus",
    "CancelDownloadResult",
];

const OWNED_DISCOVERY: &[&str] = &[
    "ContinueWatchingItem",
    "RecentlyAddedItem",
    "UpNextItem",
    "Collection",
    "SearchResult",
    "SearchSection",
    "SearchResults",
    "RemoteAccessStatus",
    "ServerCompatibility",
];

fn reference_sdl() -> String {
    std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../player/lib/graphql/schema.graphql"
    ))
    .expect("reference schema not found")
}

fn assert_group(owned: &[&str], fragment: &str, group: &str) {
    let reference = canonicalize(&reference_sdl()).unwrap();
    let ours = canonicalize(fragment).unwrap();

    for name in owned {
        let ours_line = line_for(&ours, name)
            .unwrap_or_else(|| panic!("{name} is not declared in the {group} group"));
        let reference_line = line_for(&reference, name)
            .unwrap_or_else(|| panic!("{name} is not in the reference SDL"));

        assert_eq!(
            ours_line, reference_line,
            "{name} differs from the contract"
        );
    }
}

#[test]
fn auth_types_match_the_reference() {
    assert_group(OWNED_AUTH, &mydia_api::types::auth::sdl_fragment(), "auth");
}

#[test]
fn streaming_types_match_the_reference() {
    assert_group(
        OWNED_STREAMING,
        &mydia_api::types::streaming::sdl_fragment(),
        "streaming",
    );
}

#[test]
fn discovery_types_match_the_reference() {
    assert_group(
        OWNED_DISCOVERY,
        &mydia_api::types::discovery::sdl_fragment(),
        "discovery",
    );
}

fn line_for(canonical: &str, name: &str) -> Option<String> {
    canonical
        .lines()
        .find(|line| {
            line.split_whitespace()
                .nth(1)
                .map(|candidate| candidate.trim_end_matches(['{', '(']))
                == Some(name)
        })
        .map(str::to_owned)
}
