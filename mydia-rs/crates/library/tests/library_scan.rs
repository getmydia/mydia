//! End-to-end library scanner integration test.
//!
//! Builds a fixture directory of ~100 video files spread across
//! nested sub-directories, runs the scanner, and verifies the
//! emitted [`mydia_rs_library::ScanFile`] rows have the shape U17's
//! `LibraryScanner` worker expects to map onto `media_files`.
//!
//! Also exercises the `library_scanner` `PubSub` topic and the
//! recursive-vs-flat option.

use std::path::Path;

use mydia_rs_library::scanner::{ScanOptions, Scanner};
use mydia_rs_pubsub::{topics, Pubsub};
use tempfile::TempDir;

fn touch(path: &Path) {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    std::fs::write(path, b"x").unwrap();
}

/// Build a fixture with `count` video files spread evenly across
/// `Movies/A`, `Movies/B`, and `TV/Show/Season 01` etc.
fn build_fixture(root: &Path, count: usize) {
    for i in 0..count {
        let bucket = i % 4;
        let leaf = match bucket {
            0 => format!("Movies/A/Movie.{i:03}.2020.1080p.BluRay.x264-GROUP.mkv"),
            1 => format!("Movies/B/Other.Movie.{i:03}.2021.720p.WEB-DL.x264.mkv"),
            // Append the global index so the path is unique even
            // when the episode number cycles.
            2 => format!(
                "TV/Show/Season 01/Show.S01E{:02}.{i:03}.1080p.WEB-DL.mkv",
                (i % 24) + 1
            ),
            _ => format!(
                "TV/Other/Other.S01E{:02}.{i:03}.720p.HDTV.mkv",
                (i % 24) + 1
            ),
        };
        touch(&root.join(leaf));
    }

    // Sprinkle a handful of non-video files so the extension filter
    // gets exercised.
    touch(&root.join("Movies/A/poster.jpg"));
    touch(&root.join("Movies/A/movie.nfo"));
    touch(&root.join("TV/.DS_Store"));
}

#[tokio::test(flavor = "multi_thread")]
async fn scans_fixture_directory_and_produces_media_file_rows() {
    let dir = TempDir::new().unwrap();
    build_fixture(dir.path(), 120);

    let result = Scanner::scan(dir.path(), ScanOptions::default())
        .await
        .unwrap();

    assert_eq!(
        result.files.len(),
        120,
        "expected 120 video files, got {}",
        result.files.len()
    );
    assert!(
        result.errors.is_empty(),
        "unexpected errors: {:?}",
        result.errors
    );

    // Every scanned row has the fields U17 will write to the
    // `media_files` table.
    for file in &result.files {
        assert!(file.path.is_absolute(), "expected absolute path");
        assert!(!file.filename.is_empty());
        assert!(file.size > 0);
        assert!(!file.extension.is_empty());
        assert!(file.extension.starts_with('.'));
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn non_recursive_scan_only_top_level() {
    let dir = TempDir::new().unwrap();
    touch(&dir.path().join("Top.Level.2020.mkv"));
    touch(&dir.path().join("sub/Nested.2020.mkv"));

    let opts = ScanOptions {
        recursive: false,
        ..ScanOptions::default()
    };
    let result = Scanner::scan(dir.path(), opts).await.unwrap();
    assert_eq!(result.files.len(), 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn scan_publishes_progress_events_on_library_scanner_topic() {
    let dir = TempDir::new().unwrap();
    build_fixture(dir.path(), 10);

    let bus = Pubsub::new();
    let mut rx = bus.subscribe(topics::LIBRARY_SCANNER);
    let opts = ScanOptions {
        pubsub: Some(bus.clone()),
        progress_interval: 1,
        scan_id: Some("integ-1".into()),
        ..ScanOptions::default()
    };

    let result = Scanner::scan(dir.path(), opts).await.unwrap();
    assert_eq!(result.files.len(), 10);

    let mut events = Vec::new();
    while let Ok(event) = rx.try_recv() {
        events.push(event);
    }
    // Started + at least one progress + completed
    assert!(
        events.len() >= 3,
        "expected lifecycle events, got {events:?}"
    );
}
