use std::path::Path;
use std::process::Command;

use mydia_db::pool::connect_temp;
use mydia_db::{episodes, library_paths, media_files, media_items, scan_runs, Db};
use mydia_library::scan::scan_library_path;

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
            "testsrc=size=640x360:rate=24:duration=1",
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

async fn library(db: &Db, path: &Path, kind: &str) -> library_paths::LibraryPathRow {
    library_paths::sync_from_config(db, &[(path.display().to_string(), kind.to_string())])
        .await
        .unwrap()
        .into_iter()
        .next()
        .unwrap()
}

#[tokio::test]
async fn a_movie_library_produces_items_and_files() {
    let (db, _g) = connect_temp().await.unwrap();
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

    let row = library(&db, media.path(), "movies").await;
    let outcome = scan_library_path(&db, &row).await.unwrap();

    assert_eq!(outcome.files_seen, 2);
    assert_eq!(outcome.files_indexed, 2);
    assert_eq!(outcome.files_failed, 0);

    let run = scan_runs::latest(&db, &row.id).await.unwrap().unwrap();
    assert_eq!(run.state, "completed");
}

#[tokio::test]
async fn two_files_of_one_movie_become_one_item() {
    let (db, _g) = connect_temp().await.unwrap();
    let media = tempfile::tempdir().unwrap();

    if !synthesize_all(
        media.path(),
        &[
            "The Matrix (1999)/The Matrix (1999) - 1080p.mkv",
            "The Matrix (1999)/The Matrix (1999) - 2160p.mkv",
        ],
    ) {
        return;
    }

    let row = library(&db, media.path(), "movies").await;
    scan_library_path(&db, &row).await.unwrap();

    let items: i64 = sqlx::query_scalar("SELECT count(*) FROM media_items")
        .fetch_one(db.pool())
        .await
        .unwrap();
    let files: i64 = sqlx::query_scalar("SELECT count(*) FROM media_files")
        .fetch_one(db.pool())
        .await
        .unwrap();

    assert_eq!(items, 1, "both files are the same film");
    assert_eq!(files, 2);
}

#[tokio::test]
async fn a_series_library_produces_a_show_with_episodes() {
    let (db, _g) = connect_temp().await.unwrap();
    let media = tempfile::tempdir().unwrap();

    if !synthesize_all(
        media.path(),
        &[
            "Show Name/Season 01/Show Name - S01E01.mkv",
            "Show Name/Season 01/Show Name - S01E02.mkv",
            "Show Name/Season 02/Show Name - S02E01.mkv",
        ],
    ) {
        return;
    }

    let row = library(&db, media.path(), "series").await;
    scan_library_path(&db, &row).await.unwrap();

    let shows: Vec<String> =
        sqlx::query_scalar("SELECT id FROM media_items WHERE media_type = 'tv_show'")
            .fetch_all(db.pool())
            .await
            .unwrap();

    assert_eq!(shows.len(), 1);

    let listed = episodes::list_for_show(&db, &shows[0]).await.unwrap();
    let numbering: Vec<(i64, i64)> = listed
        .iter()
        .map(|e| (e.season_number, e.episode_number))
        .collect();

    assert_eq!(numbering, vec![(1, 1), (1, 2), (2, 1)]);
}

#[tokio::test]
async fn rescanning_changes_nothing() {
    let (db, _g) = connect_temp().await.unwrap();
    let media = tempfile::tempdir().unwrap();

    if !synthesize(media.path(), "The Matrix (1999)/The Matrix (1999).mkv") {
        eprintln!("ffmpeg unavailable or failed to encode a fixture, skipping");
        return;
    }

    let row = library(&db, media.path(), "movies").await;
    scan_library_path(&db, &row).await.unwrap();
    let first: Vec<String> = sqlx::query_scalar("SELECT id FROM media_items")
        .fetch_all(db.pool())
        .await
        .unwrap();

    scan_library_path(&db, &row).await.unwrap();
    let second: Vec<String> = sqlx::query_scalar("SELECT id FROM media_items")
        .fetch_all(db.pool())
        .await
        .unwrap();

    assert_eq!(first, second, "a rescan must not churn ids");
}

#[tokio::test]
async fn a_deleted_file_is_pruned_along_with_its_item() {
    let (db, _g) = connect_temp().await.unwrap();
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

    let row = library(&db, media.path(), "movies").await;
    scan_library_path(&db, &row).await.unwrap();

    std::fs::remove_dir_all(media.path().join("Arrival (2016)")).unwrap();
    scan_library_path(&db, &row).await.unwrap();

    let titles: Vec<String> = sqlx::query_scalar("SELECT title FROM media_items ORDER BY title")
        .fetch_all(db.pool())
        .await
        .unwrap();

    assert_eq!(titles, vec!["The Matrix".to_string()]);
}

#[tokio::test]
async fn a_file_that_cannot_be_parsed_is_recorded_and_the_scan_completes() {
    let (db, _g) = connect_temp().await.unwrap();
    let media = tempfile::tempdir().unwrap();

    if !synthesize_all(
        media.path(),
        &[
            "Show Name/Season 01/Show Name - S01E01.mkv",
            // No episode marker anywhere, in a series library.
            "Show Name/loose recording.mkv",
        ],
    ) {
        return;
    }

    let row = library(&db, media.path(), "series").await;
    let outcome = scan_library_path(&db, &row).await.unwrap();

    assert_eq!(outcome.files_seen, 2);
    assert_eq!(outcome.files_indexed, 1);
    assert_eq!(outcome.files_failed, 1);

    let run = scan_runs::latest(&db, &row.id).await.unwrap().unwrap();
    assert_eq!(
        run.state, "completed",
        "one bad file must not abort the scan"
    );

    let recorded = scan_runs::issues(&db, &run.id).await.unwrap();
    assert_eq!(recorded.len(), 1);
    assert_eq!(recorded[0].reason, "unparsed");
}

#[tokio::test]
async fn a_file_ffprobe_cannot_read_is_recorded_and_skipped() {
    let (db, _g) = connect_temp().await.unwrap();
    let media = tempfile::tempdir().unwrap();

    if !synthesize_all(media.path(), &["Good Movie (2020)/Good Movie (2020).mkv"]) {
        return;
    }

    let broken = media.path().join("Bad Movie (2020)/Bad Movie (2020).mkv");
    std::fs::create_dir_all(broken.parent().unwrap()).unwrap();
    std::fs::write(&broken, b"not a container").unwrap();

    let row = library(&db, media.path(), "movies").await;
    let outcome = scan_library_path(&db, &row).await.unwrap();

    assert_eq!(outcome.files_indexed, 1);
    assert_eq!(outcome.files_failed, 1);

    let run = scan_runs::latest(&db, &row.id).await.unwrap().unwrap();
    let recorded = scan_runs::issues(&db, &run.id).await.unwrap();

    assert_eq!(recorded[0].reason, "probe_failed");
    assert!(
        recorded[0].detail.is_some(),
        "the ffprobe stderr tail is the point"
    );

    let titles: Vec<String> = sqlx::query_scalar("SELECT title FROM media_items")
        .fetch_all(db.pool())
        .await
        .unwrap();
    assert_eq!(titles, vec!["Good Movie".to_string()]);
}

#[tokio::test]
async fn an_unreadable_library_path_fails_the_run() {
    let (db, _g) = connect_temp().await.unwrap();
    let media = tempfile::tempdir().unwrap();
    let missing = media.path().join("not-there");

    let row = library(&db, &missing, "movies").await;
    let result = scan_library_path(&db, &row).await;

    assert!(result.is_err());

    let run = scan_runs::latest(&db, &row.id).await.unwrap().unwrap();
    assert_eq!(run.state, "failed");
    assert!(run.error.is_some());
    // Any error after scan_runs::start (walk, persist, prune, progress, finish)
    // marks the run failed via the outer handler — not only walk failures.
}

#[tokio::test]
async fn a_persist_failure_marks_the_run_failed() {
    let (db, _g) = connect_temp().await.unwrap();
    let media = tempfile::tempdir().unwrap();

    if !synthesize(media.path(), "The Matrix (1999)/The Matrix (1999).mkv") {
        eprintln!("ffmpeg unavailable or failed to encode a fixture, skipping");
        return;
    }

    let row = library(&db, media.path(), "movies").await;

    sqlx::query("DROP TABLE media_items")
        .execute(db.pool())
        .await
        .unwrap();

    let result = scan_library_path(&db, &row).await;
    assert!(result.is_err());

    let run = scan_runs::latest(&db, &row.id).await.unwrap().unwrap();
    assert_eq!(run.state, "failed");
    assert!(run.error.is_some());
}

#[tokio::test]
async fn the_media_file_carries_probed_facts() {
    let (db, _g) = connect_temp().await.unwrap();
    let media = tempfile::tempdir().unwrap();

    if !synthesize(media.path(), "The Matrix (1999)/The Matrix (1999).mkv") {
        eprintln!("ffmpeg unavailable or failed to encode a fixture, skipping");
        return;
    }

    let row = library(&db, media.path(), "movies").await;
    scan_library_path(&db, &row).await.unwrap();

    let item = sqlx::query_scalar::<_, String>("SELECT id FROM media_items")
        .fetch_one(db.pool())
        .await
        .unwrap();

    let files = media_files::list_for_item(&db, &item).await.unwrap();

    assert_eq!(files[0].resolution.as_deref(), Some("360p"));
    assert_eq!(files[0].codec.as_deref(), Some("H.264"));
    assert!(files[0].size.unwrap_or(0) > 0);
    assert!(files[0].duration_seconds.unwrap_or(0.0) > 0.0);
}

#[tokio::test]
async fn the_library_path_records_when_it_was_scanned() {
    let (db, _g) = connect_temp().await.unwrap();
    let media = tempfile::tempdir().unwrap();

    if !synthesize(media.path(), "The Matrix (1999)/The Matrix (1999).mkv") {
        eprintln!("ffmpeg unavailable or failed to encode a fixture, skipping");
        return;
    }

    let row = library(&db, media.path(), "movies").await;
    assert!(row.last_scan_at.is_none());

    scan_library_path(&db, &row).await.unwrap();

    let after = library_paths::find(&db, &row.id).await.unwrap().unwrap();
    assert!(after.last_scan_at.is_some());

    // Silence the unused-import warning for media_items in this file.
    let _ = media_items::find(&db, "nothing").await.unwrap();
}
