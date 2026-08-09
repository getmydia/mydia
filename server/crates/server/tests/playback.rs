//! The player's own playback documents, run against the server.

mod support;

use mydia_server::test_support::{app_over_library, post_graphql_with_variables};

/// The MediaFileFragment as the player declares it
/// (player/lib/graphql/fragments/media_file_fragment.graphql), inlined into a
/// movie query. If this document stops matching the player's, playback breaks
/// in a way no unit test sees.
const MOVIE_WITH_FILES: &str = r#"
query MovieDetail($id: ID!) {
  movie(id: $id) {
    id
    files {
      id
      resolution
      codec
      audioCodec
      hdrFormat
      size
      bitrate
      directPlaySupported
      streamUrl
      directPlayUrl
      subtitles { trackId language title format embedded url(format: VTT) }
    }
  }
}
"#;

const CANDIDATES: &str = r#"
query StreamingCandidates($contentType: String!, $id: ID!) {
  streamingCandidates(contentType: $contentType, id: $id) {
    fileId
    candidates { strategy mime container videoCodec audioCodec }
    metadata { duration width height bitrate resolution hdrFormat originalCodec originalAudioCodec container }
  }
}
"#;

#[tokio::test]
async fn a_scanned_movie_carries_relative_playback_urls() {
    let media = support::movie_library().await;
    let (app, _guard, token) =
        app_over_library("admin", "adminadmin", media.path(), "movies").await;

    let id = support::first_movie_id(app.clone(), &token).await;

    let body = post_graphql_with_variables(
        app,
        MOVIE_WITH_FILES,
        serde_json::json!({ "id": id }),
        &token,
    )
    .await;

    let file = &body["data"]["movie"]["files"][0];
    let file_id = file["id"].as_str().unwrap();

    assert_eq!(file["directPlaySupported"], serde_json::json!(true));
    assert_eq!(
        file["streamUrl"].as_str().unwrap(),
        format!("/api/v1/stream/file/{file_id}")
    );
    assert_eq!(
        file["directPlayUrl"].as_str().unwrap(),
        format!("/api/v1/stream/file/{file_id}?strategy=DIRECT_PLAY")
    );
}

#[tokio::test]
async fn streaming_candidates_lead_with_something_the_player_can_direct_play() {
    let media = support::movie_library().await;
    let (app, _guard, token) =
        app_over_library("admin", "adminadmin", media.path(), "movies").await;

    let id = support::first_movie_id(app.clone(), &token).await;

    let body = post_graphql_with_variables(
        app,
        CANDIDATES,
        serde_json::json!({ "contentType": "movie", "id": id }),
        &token,
    )
    .await;

    let result = &body["data"]["streamingCandidates"];
    assert!(result["fileId"].is_string());

    let first = result["candidates"][0]["strategy"].as_str().unwrap();
    assert!(
        matches!(first, "DIRECT_PLAY" | "REMUX" | "HLS_COPY"),
        "led with {first}"
    );

    // The metadata block is what the player uses for the real runtime.
    assert!(result["metadata"]["duration"].as_f64().unwrap() > 0.0);
    assert_eq!(result["metadata"]["height"], serde_json::json!(720));
}

#[tokio::test]
async fn an_unknown_id_is_a_graphql_error_not_a_null() {
    // player_screen.dart:1360-1395 self-heals only when the rejection arrives
    // as a GraphQL error with no transport error beside it.
    let media = support::movie_library().await;
    let (app, _guard, token) =
        app_over_library("admin", "adminadmin", media.path(), "movies").await;

    let body = post_graphql_with_variables(
        app,
        CANDIDATES,
        serde_json::json!({ "contentType": "movie", "id": "does-not-exist" }),
        &token,
    )
    .await;

    assert!(body["errors"].as_array().is_some_and(|e| !e.is_empty()));
}

#[tokio::test]
async fn subtitle_tracks_carry_a_url_the_player_can_fetch() {
    let media = support::library_with_sidecar().await;
    let (app, _guard, token) =
        app_over_library("admin", "adminadmin", media.path(), "movies").await;

    let id = support::first_movie_id(app.clone(), &token).await;

    let body = post_graphql_with_variables(
        app,
        MOVIE_WITH_FILES,
        serde_json::json!({ "id": id }),
        &token,
    )
    .await;

    let file = &body["data"]["movie"]["files"][0];
    let file_id = file["id"].as_str().unwrap();
    let tracks = file["subtitles"].as_array().unwrap();

    let external = tracks
        .iter()
        .find(|t| t["embedded"] == serde_json::json!(false))
        .expect("the sidecar should appear as an external track");

    assert_eq!(external["language"], serde_json::json!("eng"));
    assert_eq!(external["format"], serde_json::json!("srt"));
    // extractor.ex:203-207 titles external tracks this way.
    assert_eq!(external["title"], serde_json::json!("English (External)"));

    let track_id = external["trackId"].as_str().unwrap();
    assert_eq!(
        external["url"].as_str().unwrap(),
        format!("/api/player/v1/subtitles/file/{file_id}/{track_id}?format=vtt")
    );
}

/// Every playback-related document the player ships, run verbatim against the
/// server. Read from the repository rather than copied, so a change to the
/// player's documents fails here rather than drifting silently.
#[tokio::test]
async fn every_player_playback_document_resolves() {
    let media = support::library_with_sidecar().await;
    let (app, _guard, token) =
        app_over_library("admin", "adminadmin", media.path(), "movies").await;

    let id = support::first_movie_id(app.clone(), &token).await;
    let file_id = support::first_file_id(app.clone(), &token).await;

    // Path is relative to this package's manifest dir (server/crates/server),
    // not the process cwd, matching sdl_parity and the other contract readers.
    let fragment = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../player/lib/graphql/fragments/media_file_fragment.graphql"
    ))
    .expect("the player's MediaFileFragment should be readable from the workspace");

    let document = format!(
        "{fragment}\n{}",
        r#"
query Probe($id: ID!) {
  movie(id: $id) { id files { ...MediaFileFragment } }
}
"#
    );

    let body = post_graphql_with_variables(
        app.clone(),
        &document,
        serde_json::json!({ "id": id }),
        &token,
    )
    .await;

    assert!(
        body["errors"].is_null(),
        "the player's own fragment did not resolve: {}",
        body["errors"]
    );

    // And the candidates document, by file id rather than by movie, which is
    // the path player_screen.dart takes first.
    let body = post_graphql_with_variables(
        app,
        CANDIDATES,
        serde_json::json!({ "contentType": "file", "id": file_id }),
        &token,
    )
    .await;

    assert!(body["errors"].is_null(), "{}", body["errors"]);
    assert_eq!(
        body["data"]["streamingCandidates"]["fileId"],
        serde_json::json!(file_id)
    );
}
