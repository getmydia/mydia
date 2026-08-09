//! Walk, parse, probe, group, persist, prune.
//!
//! Rule one of the design's error handling: a scan never aborts on one bad
//! file. Every failure is recorded against the run with a reason, and the scan
//! completes. Only a failure of the library path itself fails the run.

use std::path::{Path, PathBuf};

use mydia_db::library_paths::LibraryPathRow;
use mydia_db::{episodes, library_paths, media_files, media_items, scan_runs, Db};

use crate::ffprobe::{self, FileFacts};
use crate::names::identity_key;
use crate::parser::{self, LibraryKind, ParsedFile, ParsedKind};
use crate::walk::{self, VideoFile};
use crate::LibraryError;

/// Progress is written to the database every this many files, so a long scan
/// is visible while it runs without a write per file.
const PROGRESS_EVERY: i64 = 25;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ScanOutcome {
    pub files_seen: i64,
    pub files_indexed: i64,
    pub files_failed: i64,
}

/// Scans every configured library path, in order, and keeps going when one
/// fails. A broken mount must not stop the others being indexed.
pub async fn scan_all(db: &Db) -> Result<Vec<(String, ScanOutcome)>, LibraryError> {
    let paths = library_paths::list(db).await?;
    let mut outcomes = Vec::new();

    for row in paths {
        if !row.monitored {
            continue;
        }

        match scan_library_path(db, &row).await {
            Ok(outcome) => outcomes.push((row.id.clone(), outcome)),
            Err(error) => {
                tracing::warn!(path = %row.path, %error, "the library path could not be scanned");
            }
        }
    }

    Ok(outcomes)
}

pub async fn scan_library_path(db: &Db, row: &LibraryPathRow) -> Result<ScanOutcome, LibraryError> {
    let kind = LibraryKind::from_str(&row.library_type).ok_or_else(|| {
        LibraryError::UnknownLibraryType {
            path: row.path.clone(),
            library_type: row.library_type.clone(),
        }
    })?;

    let run = scan_runs::start(db, &row.id).await?;
    let root = PathBuf::from(&row.path);

    match scan_library_path_inner(db, row, kind, &run, &root).await {
        Ok(outcome) => Ok(outcome),
        Err(error) => {
            fail_run_best_effort(db, &run.id, &error).await;
            Err(error)
        }
    }
}

async fn fail_run_best_effort(db: &Db, run_id: &str, error: &LibraryError) {
    let _ = scan_runs::fail(db, run_id, &error.to_string()).await;
}

async fn scan_library_path_inner(
    db: &Db,
    row: &LibraryPathRow,
    kind: LibraryKind,
    run: &scan_runs::ScanRunRow,
    root: &Path,
) -> Result<ScanOutcome, LibraryError> {
    let files = walk::walk(root)?;

    let mut outcome = ScanOutcome {
        files_seen: files.len() as i64,
        ..Default::default()
    };

    let mut indexed_paths: Vec<String> = Vec::with_capacity(files.len());

    for file in &files {
        let display = file.path.display().to_string();

        let Some(parsed) = parser::parse(&file.path, root, kind) else {
            outcome.files_failed += 1;
            scan_runs::record_issue(
                db,
                &run.id,
                &display,
                "unparsed",
                Some("no title, season or episode could be read from the name"),
            )
            .await?;
            continue;
        };

        let probe_path = file.path.clone();
        let probed = tokio::task::spawn_blocking(move || ffprobe::probe(&probe_path))
            .await
            .map_err(|e| LibraryError::Ffprobe {
                path: display.clone(),
                detail: format!("the probe task did not finish: {e}"),
            })?;

        let facts = match probed {
            Ok(facts) => facts,
            Err(error) => {
                outcome.files_failed += 1;
                scan_runs::record_issue(
                    db,
                    &run.id,
                    &display,
                    "probe_failed",
                    Some(&error.to_string()),
                )
                .await?;
                continue;
            }
        };

        persist(db, row, &parsed, file, &facts).await?;

        indexed_paths.push(display);
        outcome.files_indexed += 1;

        if outcome.files_indexed % PROGRESS_EVERY == 0 {
            scan_runs::record_progress(
                db,
                &run.id,
                outcome.files_seen,
                outcome.files_indexed,
                outcome.files_failed,
            )
            .await?;
        }
    }

    // Rows only. Nothing inside the library is removed, because Mydia Server
    // has no delete capability at all.
    media_files::prune_outside(db, &row.id, &indexed_paths).await?;
    media_files::prune_empty_items(db, &row.id).await?;

    scan_runs::record_progress(
        db,
        &run.id,
        outcome.files_seen,
        outcome.files_indexed,
        outcome.files_failed,
    )
    .await?;
    scan_runs::finish(db, &run.id).await?;
    library_paths::touch_scanned(db, &row.id).await?;

    Ok(outcome)
}

async fn persist(
    db: &Db,
    row: &LibraryPathRow,
    parsed: &ParsedFile,
    file: &VideoFile,
    facts: &FileFacts,
) -> Result<(), LibraryError> {
    let media_type = match parsed.kind {
        ParsedKind::Movie => "movie",
        ParsedKind::Episode { .. } => "tv_show",
    };

    let item = media_items::upsert(
        db,
        media_items::NewMediaItem {
            library_path_id: row.id.clone(),
            media_type: media_type.to_string(),
            title: parsed.title.clone(),
            identity_key: identity_key(&parsed.title),
            year: parsed.year.map(i64::from),
        },
    )
    .await?;

    let owner = match parsed.kind {
        ParsedKind::Movie => media_files::Owner::Item(item.id),
        ParsedKind::Episode {
            season, episode, ..
        } => {
            let row = episodes::upsert(
                db,
                episodes::NewEpisode {
                    show_id: item.id,
                    season_number: i64::from(season),
                    episode_number: i64::from(episode),
                },
            )
            .await?;

            media_files::Owner::Episode(row.id)
        }
    };

    let subtitle_tracks = serde_json::to_string(&facts.subtitle_tracks).ok();

    let stored = media_files::upsert(
        db,
        media_files::NewMediaFile {
            owner,
            path: file.path.display().to_string(),
            size: i64::try_from(file.size).ok(),
            resolution: facts.resolution.clone(),
            codec: facts.codec.clone(),
            audio_codec: facts.audio_codec.clone(),
            hdr_format: facts.hdr_format.clone(),
            bitrate: facts.bitrate,
            duration_seconds: facts.duration_seconds,
            container: facts.container.clone(),
            width: facts.width,
            height: facts.height,
            subtitle_tracks,
            mtime: file.mtime.to_rfc3339(),
        },
    )
    .await?;

    // Sidecar subtitles are cheap: the directory is already in the page
    // cache from the walk, and nothing is probed. `seen` is the keep list for
    // prune_for_file; an empty list deletes every row for this file, which is
    // correct only when no sidecars remain on disk.
    let sidecars = crate::sidecar::discover(std::path::Path::new(&stored.path));
    let seen: Vec<String> = sidecars.iter().map(|s| s.path.clone()).collect();

    for sidecar in sidecars {
        mydia_db::external_subtitles::upsert(
            db,
            mydia_db::external_subtitles::NewExternalSubtitle {
                media_file_id: stored.id.clone(),
                path: sidecar.path,
                language: sidecar.language,
                format: sidecar.format,
            },
        )
        .await?;
    }

    mydia_db::external_subtitles::prune_for_file(db, &stored.id, &seen).await?;

    Ok(())
}
