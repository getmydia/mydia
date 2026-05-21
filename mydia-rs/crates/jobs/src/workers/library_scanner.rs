//! Port of `lib/mydia/jobs/library_scanner.ex` (~1463 LOC in Phoenix).
//!
//! Scans configured library paths for media files, detects new /
//! modified / deleted files, and updates the database. The bulk of the
//! work lives in [`mydia_rs_library::scanner::Scanner`] (the
//! directory walker) and the related building-block modules in
//! `mydia-rs-library` (file grouping, release parsing, metadata
//! enrichment). This worker is the orchestrator: it resolves the
//! `LibraryPath` row, optionally applies the random startup delay (for
//! the cron-driven "scan all" mode), and dispatches to one of three
//! sub-flows.

use std::path::PathBuf;
use std::time::Duration;

use apalis::prelude::Data;
use chrono::Utc;
use mydia_rs_library::{ScanOptions, Scanner};
use mydia_rs_pubsub::{topics, Event};
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

/// Maximum random startup delay applied to the cron-driven "scan all"
/// run. Phoenix uses 30 minutes; the spread reduces metadata-relay
/// load across self-hosted instances all ticking at the top of the
/// hour.
pub const MAX_STARTUP_DELAY: Duration = Duration::from_secs(30 * 60);

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct LibraryScannerArgs {
    /// Scan one specific library path by id. Highest precedence.
    #[serde(default)]
    pub library_path_id: Option<String>,
    /// Scan every monitored path of this `LibraryKind` (`"movies"`,
    /// `"series"`, ...). Second-precedence.
    #[serde(default)]
    pub library_type: Option<String>,
    /// Skip the random delay even on cron-driven scans. Manual UI
    /// triggers set this to `true`.
    #[serde(default)]
    pub skip_delay: bool,
}

pub const QUEUE: Queue = Queue::Media;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn library_scanner(
    args: LibraryScannerArgs,
    ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    let scan_all = args.library_path_id.is_none() && args.library_type.is_none();
    if scan_all && !args.skip_delay {
        let delay = random_startup_delay();
        let minutes = (delay.as_secs() as f64) / 60.0;
        tracing::info!(
            delay_minutes = format!("{minutes:.1}"),
            "library scan scheduled; waiting before starting"
        );
        tokio::time::sleep(delay).await;
    }

    let start = std::time::Instant::now();

    let result = if let Some(id) = args.library_path_id.as_deref() {
        scan_single_library(&ctx, id).await
    } else if let Some(library_type) = args.library_type.as_deref() {
        scan_libraries_by_type(&ctx, library_type).await
    } else {
        scan_all_libraries(&ctx).await
    };

    let elapsed = start.elapsed();
    match &result {
        Ok(()) => tracing::info!(
            duration_ms = elapsed.as_millis(),
            library_path_id = args.library_path_id.as_deref().unwrap_or(""),
            library_type = args.library_type.as_deref().unwrap_or(""),
            "library scan job completed"
        ),
        Err(err) => tracing::error!(
            duration_ms = elapsed.as_millis(),
            library_path_id = args.library_path_id.as_deref().unwrap_or(""),
            library_type = args.library_type.as_deref().unwrap_or(""),
            error = %err,
            "library scan job failed"
        ),
    }
    result
}

fn random_startup_delay() -> Duration {
    use std::time::SystemTime;
    // Simple stdlib-only random — converting nanoseconds-since-epoch
    // mod max_delay is good enough for staggered startups. Avoids a
    // `rand` dependency for one use.
    let nanos: u64 = u64::from(
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0),
    );
    let max_secs = MAX_STARTUP_DELAY.as_secs();
    let seconds = nanos.checked_rem(max_secs).unwrap_or(0);
    Duration::from_secs(seconds)
}

/// Row shape we select from `library_paths`. Narrow on purpose.
#[derive(Debug, Clone)]
struct LibraryPathRow {
    id: String,
    path: String,
    kind: String,
    monitored: bool,
}

async fn list_library_paths(db: &mydia_rs_db::Db) -> Result<Vec<LibraryPathRow>, JobsError> {
    use mydia_rs_db::Db;
    let rows: Vec<(String, String, String, bool)> = match db {
        Db::Sqlite(pool) => {
            sqlx::query_as(
                "SELECT id, path, type, monitored FROM library_paths ORDER BY inserted_at",
            )
            .fetch_all(pool)
            .await?
        }
        Db::Postgres(pool) => {
            sqlx::query_as(
                "SELECT id, path, type, monitored FROM library_paths ORDER BY inserted_at",
            )
            .fetch_all(pool)
            .await?
        }
    };
    Ok(rows
        .into_iter()
        .map(|(id, path, kind, monitored)| LibraryPathRow {
            id,
            path,
            kind,
            monitored,
        })
        .collect())
}

async fn get_library_path(db: &mydia_rs_db::Db, id: &str) -> Result<LibraryPathRow, JobsError> {
    use mydia_rs_db::Db;
    let row: Option<(String, String, String, bool)> = match db {
        Db::Sqlite(pool) => {
            sqlx::query_as("SELECT id, path, type, monitored FROM library_paths WHERE id = ?")
                .bind(id)
                .fetch_optional(pool)
                .await?
        }
        Db::Postgres(pool) => {
            sqlx::query_as("SELECT id, path, type, monitored FROM library_paths WHERE id = $1")
                .bind(id)
                .fetch_optional(pool)
                .await?
        }
    };
    row.map(|(id, path, kind, monitored)| LibraryPathRow {
        id,
        path,
        kind,
        monitored,
    })
    .ok_or_else(|| JobsError::NotFound(format!("library_path {id}")))
}

async fn scan_all_libraries(ctx: &AppContext) -> Result<(), JobsError> {
    tracing::info!("starting scan of all monitored library paths");
    let paths = list_library_paths(&ctx.db).await?;
    let monitored: Vec<_> = paths.into_iter().filter(|p| p.monitored).collect();
    tracing::info!(count = monitored.len(), "found monitored library paths");

    let mut successful = 0u32;
    let mut failed = 0u32;
    for path in monitored {
        match scan_library_path(ctx, &path).await {
            Ok(()) => successful += 1,
            Err(err) => {
                failed += 1;
                tracing::warn!(library_path_id = %path.id, error = %err, "scan failed");
            }
        }
    }
    tracing::info!(successful, failed, "library scan completed");
    Ok(())
}

async fn scan_libraries_by_type(ctx: &AppContext, library_type: &str) -> Result<(), JobsError> {
    tracing::info!(library_type, "starting scan of library paths by type");
    let paths = list_library_paths(&ctx.db).await?;
    let of_type: Vec<_> = paths
        .into_iter()
        .filter(|p| p.kind == library_type)
        .collect();
    tracing::info!(library_type, count = of_type.len(), "matched paths");

    let mut successful = 0u32;
    let mut failed = 0u32;
    for path in of_type {
        match scan_library_path(ctx, &path).await {
            Ok(()) => successful += 1,
            Err(err) => {
                failed += 1;
                tracing::warn!(library_path_id = %path.id, error = %err, "scan failed");
            }
        }
    }
    tracing::info!(library_type, successful, failed, "by-type scan completed");
    Ok(())
}

async fn scan_single_library(ctx: &AppContext, id: &str) -> Result<(), JobsError> {
    tracing::info!(library_path_id = id, "starting scan of single library path");
    let path = get_library_path(&ctx.db, id).await?;
    scan_library_path(ctx, &path).await
}

async fn scan_library_path(
    ctx: &AppContext,
    library_path: &LibraryPathRow,
) -> Result<(), JobsError> {
    tracing::debug!(
        id = %library_path.id,
        path = %library_path.path,
        kind = %library_path.kind,
        "scanning library path"
    );

    // Broadcast scan started — mirrors Phoenix:
    // `Phoenix.PubSub.broadcast(@pubsub, "library_scanner", {:library_scan_started, ...})`.
    ctx.pubsub.publish(
        topics::LIBRARY_SCANNER,
        Event::from_json(serde_json::json!({
            "event": "scan_started",
            "library_path_id": library_path.id,
            "type": library_path.kind,
        })),
    );

    // Mark scan as in progress (skip for "runtime" paths — paths
    // belonging to a mounted USB device etc. live outside the DB
    // table). The flag for that is `updatable_library_path?` in
    // Phoenix; the Rust port simply attempts an UPDATE and ignores 0
    // rows affected.
    let _ = mark_scan_in_progress(&ctx.db, &library_path.id).await;

    let scan_id = uuid::Uuid::new_v4().to_string();
    let opts = ScanOptions {
        recursive: true,
        extensions: None,
        pubsub: Some(ctx.pubsub.clone()),
        progress_interval: 100,
        scan_id: Some(scan_id.clone()),
    };

    let scan_result = match Scanner::scan(PathBuf::from(&library_path.path), opts).await {
        Ok(r) => r,
        Err(err) => {
            return handle_scan_error(ctx, &library_path.id, &err.to_string()).await;
        }
    };

    let file_count = scan_result.files.len();
    let error_count = scan_result.errors.len();
    tracing::info!(
        library_path_id = %library_path.id,
        file_count,
        error_count,
        "scan complete"
    );

    // The Phoenix worker's `process_scan_result_by_type/2` does the
    // diff against `media_files` (new / modified / deleted),
    // enqueues per-file `MediaImport`, `FileAnalysis`, and
    // `ThumbnailGeneration` jobs, and writes back NFO sidecars. Those
    // writes need the U5 model layer to land; for U17 the orchestrator
    // shape and progress reporting are wire-compatible with Phoenix
    // while the actual diffing remains delegated to Phoenix during the
    // parallel window.
    mark_scan_completed(&ctx.db, &library_path.id).await.ok();
    Ok(())
}

async fn handle_scan_error(
    ctx: &AppContext,
    library_path_id: &str,
    error: &str,
) -> Result<(), JobsError> {
    tracing::error!(library_path_id, %error, "library scan error");
    mark_scan_failed(&ctx.db, library_path_id, error).await.ok();
    ctx.pubsub.publish(
        topics::LIBRARY_SCANNER,
        Event::from_json(serde_json::json!({
            "event": "scan_failed",
            "library_path_id": library_path_id,
            "error": error,
        })),
    );
    Err(JobsError::WorkerError(error.to_owned()))
}

async fn mark_scan_in_progress(db: &mydia_rs_db::Db, id: &str) -> Result<(), JobsError> {
    use mydia_rs_db::Db;
    let now = Utc::now();
    match db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "UPDATE library_paths \
                 SET last_scan_status = 'in_progress', last_scan_error = NULL, updated_at = ? \
                 WHERE id = ?",
            )
            .bind(now.to_rfc3339())
            .bind(id)
            .execute(pool)
            .await?;
        }
        Db::Postgres(pool) => {
            sqlx::query(
                "UPDATE library_paths \
                 SET last_scan_status = 'in_progress', last_scan_error = NULL, updated_at = $1 \
                 WHERE id = $2",
            )
            .bind(now)
            .bind(id)
            .execute(pool)
            .await?;
        }
    }
    Ok(())
}

async fn mark_scan_completed(db: &mydia_rs_db::Db, id: &str) -> Result<(), JobsError> {
    use mydia_rs_db::Db;
    let now = Utc::now();
    match db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "UPDATE library_paths \
                 SET last_scan_status = 'completed', last_scan_at = ?, last_scan_error = NULL, updated_at = ? \
                 WHERE id = ?",
            )
            .bind(now.to_rfc3339())
            .bind(now.to_rfc3339())
            .bind(id)
            .execute(pool)
            .await?;
        }
        Db::Postgres(pool) => {
            sqlx::query(
                "UPDATE library_paths \
                 SET last_scan_status = 'completed', last_scan_at = $1, last_scan_error = NULL, updated_at = $2 \
                 WHERE id = $3",
            )
            .bind(now)
            .bind(now)
            .bind(id)
            .execute(pool)
            .await?;
        }
    }
    Ok(())
}

async fn mark_scan_failed(db: &mydia_rs_db::Db, id: &str, error: &str) -> Result<(), JobsError> {
    use mydia_rs_db::Db;
    let now = Utc::now();
    match db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "UPDATE library_paths \
                 SET last_scan_status = 'failed', last_scan_error = ?, updated_at = ? \
                 WHERE id = ?",
            )
            .bind(error)
            .bind(now.to_rfc3339())
            .bind(id)
            .execute(pool)
            .await?;
        }
        Db::Postgres(pool) => {
            sqlx::query(
                "UPDATE library_paths \
                 SET last_scan_status = 'failed', last_scan_error = $1, updated_at = $2 \
                 WHERE id = $3",
            )
            .bind(error)
            .bind(now)
            .bind(id)
            .execute(pool)
            .await?;
        }
    }
    Ok(())
}
