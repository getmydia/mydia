use std::path::Path;
use std::process::Command;

use mydia_server::test_support::{
    app_over_library, post_graphql_authed, post_graphql_with_variables,
};

/// Writes a one-second real video. Returns false when ffmpeg cannot be run
/// or the encode fails (missing binary, codec, permissions, etc.).
fn synthesize(root: &Path, relative: &str) -> bool {
    let path = root.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();

    Command::new("ffmpeg")
        .args([
            "-v",
            "quiet",
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=1280x720:rate=24:duration=1",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-y",
        ])
        .arg(&path)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Synthesizes every relative path, or skips the calling test when any encode
/// fails. Returns true when the fixtures are ready.
fn synthesize_all(root: &Path, relatives: &[&str]) -> bool {
    for relative in relatives {
        if !synthesize(root, relative) {
            eprintln!("ffmpeg unavailable or failed to encode a fixture, skipping");
            return false;
        }
    }
    true
}

/// MoviesList from player/lib/graphql/queries/movies_list.graphql, with its
/// two fragments inlined.
const MOVIES_LIST: &str = r#"
query MoviesList {
  movies(first: 20) {
    edges {
      node {
        id title year overview runtime genres contentRating rating
        artwork { posterUrl backdropUrl thumbnailUrl }
        progress { positionSeconds durationSeconds percentage watched lastWatchedAt }
        isFavorite
      }
      cursor
    }
    pageInfo { hasNextPage hasPreviousPage startCursor endCursor }
    totalCount
  }
}
"#;

/// TvShowsList from player/lib/graphql/queries/tv_shows_list.graphql.
const TV_SHOWS_LIST: &str = r#"
query TvShowsList {
  tvShows(first: 20) {
    edges {
      node {
        id title year overview status genres contentRating rating
        seasonCount episodeCount
        artwork { posterUrl backdropUrl thumbnailUrl }
        isFavorite
        nextEpisode { id seasonNumber episodeNumber title }
      }
      cursor
    }
    pageInfo { hasNextPage hasPreviousPage startCursor endCursor }
    totalCount
  }
}
"#;

/// SeasonEpisodes from player/lib/graphql/queries/season_episodes.graphql.
const SEASON_EPISODES: &str = r#"
query SeasonEpisodes($showId: ID!, $seasonNumber: Int!) {
  seasonEpisodes(showId: $showId, seasonNumber: $seasonNumber) {
    id seasonNumber episodeNumber title overview airDate runtime monitored
    thumbnailUrl hasFile
    progress { positionSeconds durationSeconds percentage watched lastWatchedAt }
    files {
      id resolution codec audioCodec hdrFormat size bitrate
      directPlaySupported streamUrl directPlayUrl
      subtitles { trackId language title format embedded url(format: VTT) }
    }
  }
}
"#;

/// MovieDetail from player/lib/graphql/queries/movie_detail.graphql.
const MOVIE_DETAIL: &str = r#"
query MovieDetail($id: ID!) {
  movie(id: $id) {
    id title originalTitle year overview runtime genres contentRating rating
    tmdbId imdbId category monitored addedAt
    artwork { posterUrl backdropUrl thumbnailUrl }
    progress { positionSeconds durationSeconds percentage watched lastWatchedAt }
    files {
      id resolution codec audioCodec hdrFormat size bitrate
      directPlaySupported streamUrl directPlayUrl
      subtitles { trackId language title format embedded url(format: VTT) }
    }
    isFavorite
  }
}
"#;

#[tokio::test]
async fn the_player_can_list_a_scanned_movie_library() {
    let media = tempfile::tempdir().unwrap();

    if !synthesize_all(
        media.path(),
        &[
            "The Matrix (1999)/The Matrix (1999).mkv",
            "Arrival (2016)/Arrival (2016).mkv",
        ],
    ) {
        return;
    }

    let (app, _guard, token) = app_over_library("alice", "hunter2", media.path(), "movies").await;

    let body = post_graphql_authed(app, MOVIES_LIST, &token).await;

    assert_eq!(body.get("errors"), None, "unexpected errors: {body}");

    let movies = &body["data"]["movies"];
    assert_eq!(movies["totalCount"], 2);
    assert_eq!(movies["edges"].as_array().unwrap().len(), 2);

    // Title ascending is the default.
    assert_eq!(movies["edges"][0]["node"]["title"], "Arrival");
    assert_eq!(movies["edges"][0]["node"]["year"], 2016);
    assert_eq!(movies["edges"][1]["node"]["title"], "The Matrix");

    // Slice 2b fills these in. Null is a field the player skips, not a
    // screen it loses.
    assert!(movies["edges"][0]["node"]["overview"].is_null());
    assert_eq!(movies["edges"][0]["node"]["isFavorite"], false);
    assert!(movies["edges"][0]["node"]["progress"].is_null());
}

#[tokio::test]
async fn a_movie_detail_query_returns_its_file_facts() {
    let media = tempfile::tempdir().unwrap();

    if !synthesize_all(media.path(), &["The Matrix (1999)/The Matrix (1999).mkv"]) {
        return;
    }

    let (app, _guard, token) = app_over_library("alice", "hunter2", media.path(), "movies").await;

    let list = post_graphql_authed(app.clone(), MOVIES_LIST, &token).await;
    assert_eq!(list.get("errors"), None, "unexpected errors: {list}");
    let id = list["data"]["movies"]["edges"][0]["node"]["id"]
        .as_str()
        .expect("the list returned a movie")
        .to_string();

    let body =
        post_graphql_with_variables(app, MOVIE_DETAIL, serde_json::json!({ "id": id }), &token)
            .await;

    assert_eq!(body.get("errors"), None, "unexpected errors: {body}");

    let movie = &body["data"]["movie"];
    assert_eq!(movie["title"], "The Matrix");
    assert_eq!(movie["category"], "MOVIE");
    assert_eq!(movie["monitored"], false);

    let file = &movie["files"][0];
    assert_eq!(file["resolution"], "720p");
    assert_eq!(file["codec"], "H.264");
    assert!(file["size"].as_i64().unwrap() > 0);

    // Playback lands in Slice 3.
    assert!(file["streamUrl"].is_null());
    assert!(file["directPlaySupported"].is_null());
}

#[tokio::test]
async fn the_player_can_list_shows_and_drill_into_a_season() {
    let media = tempfile::tempdir().unwrap();

    if !synthesize_all(
        media.path(),
        &[
            "Show Name (2015)/Season 01/Show Name - S01E01.mkv",
            "Show Name (2015)/Season 01/Show Name - S01E02.mkv",
            "Show Name (2015)/Season 02/Show Name - S02E01.mkv",
        ],
    ) {
        return;
    }

    let (app, _guard, token) = app_over_library("alice", "hunter2", media.path(), "series").await;

    let list = post_graphql_authed(app.clone(), TV_SHOWS_LIST, &token).await;

    assert_eq!(list.get("errors"), None, "unexpected errors: {list}");

    let show = &list["data"]["tvShows"]["edges"][0]["node"];
    assert_eq!(show["title"], "Show Name");
    assert_eq!(show["year"], 2015);
    assert_eq!(show["seasonCount"], 2);
    assert_eq!(show["episodeCount"], 3);
    assert_eq!(show["nextEpisode"]["seasonNumber"], 1);
    assert_eq!(show["nextEpisode"]["episodeNumber"], 1);

    let show_id = show["id"].as_str().expect("the list returned a show");

    let body = post_graphql_with_variables(
        app,
        SEASON_EPISODES,
        serde_json::json!({ "showId": show_id, "seasonNumber": 1 }),
        &token,
    )
    .await;

    assert_eq!(body.get("errors"), None, "unexpected errors: {body}");

    let episodes = body["data"]["seasonEpisodes"].as_array().unwrap();
    assert_eq!(episodes.len(), 2);
    assert_eq!(episodes[0]["episodeNumber"], 1);
    assert_eq!(episodes[1]["episodeNumber"], 2);
    assert_eq!(episodes[0]["hasFile"], true);
    assert_eq!(episodes[0]["files"][0]["resolution"], "720p");
}

#[tokio::test]
async fn an_empty_library_still_answers_the_list_query() {
    let media = tempfile::tempdir().unwrap();

    let (app, _guard, token) = app_over_library("alice", "hunter2", media.path(), "movies").await;

    let body = post_graphql_authed(app, MOVIES_LIST, &token).await;

    assert_eq!(body.get("errors"), None, "unexpected errors: {body}");
    assert_eq!(body["data"]["movies"]["totalCount"], 0);
    assert_eq!(body["data"]["movies"]["edges"].as_array().unwrap().len(), 0);
    assert_eq!(body["data"]["movies"]["pageInfo"]["hasNextPage"], false);
}

#[tokio::test]
async fn browsing_requires_authentication() {
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;

    let media = tempfile::tempdir().unwrap();
    let (app, _guard, _token) = app_over_library("alice", "hunter2", media.path(), "movies").await;

    let request = Request::builder()
        .method("POST")
        .uri("/api/graphql")
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({ "query": MOVIES_LIST }).to_string(),
        ))
        .unwrap();

    let response = app.oneshot(request).await.unwrap();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();

    assert!(body["errors"].is_array(), "expected an error, got {body}");
    assert_eq!(body["errors"][0]["extensions"]["code"], "UNAUTHENTICATED");
}
