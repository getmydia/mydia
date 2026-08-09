//! Shared fixtures for the media tests.

use axum::Router;
use mydia_server::test_support::post_graphql_authed;

/// A one-movie library on disk: a short real H.264/AAC MP4, which is the
/// direct-play case, laid out the way the scanner expects.
pub async fn movie_library() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let movie = dir.path().join("Test Film (2019)");
    std::fs::create_dir_all(&movie).unwrap();

    synthesize(&movie.join("Test Film (2019) - 720p.mp4"));

    dir
}

/// Writes a two-second 720p H.264/AAC file. Panics rather than skipping,
/// because a playback slice cannot be meaningfully verified without ffmpeg.
pub fn synthesize(path: &std::path::Path) {
    let status = std::process::Command::new("ffmpeg")
        .args([
            "-v",
            "quiet",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=1280x720:rate=24:duration=2",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:duration=2",
            "-c:v",
            "libx264",
            "-profile:v",
            "high",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
        ])
        .arg(path)
        .status()
        .expect("ffmpeg must be on PATH to run the playback tests");

    assert!(
        status.success(),
        "ffmpeg failed to synthesize {}",
        path.display()
    );
}

pub async fn first_movie_id(app: Router, token: &str) -> String {
    let body = post_graphql_authed(app, "{ movies { edges { node { id } } } }", token).await;

    body["data"]["movies"]["edges"][0]["node"]["id"]
        .as_str()
        .expect("the scan should have produced a movie")
        .to_string()
}
