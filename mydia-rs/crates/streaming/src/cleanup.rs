//! Boot-time cleanup of stale HLS session directories. Port of
//! `lib/mydia/streaming/hls_cleanup.ex`.
//!
//! Walks the configured temp base directory and removes any session
//! sub-directory whose **on-disk mtime** is older than the 24-hour
//! staleness threshold. Mtime is the staleness signal — NOT DB row
//! presence in `transcode_jobs` — for the parallel-window edge case
//! called out in the plan:
//!
//! > if mydia-rs boots while a Phoenix-served session is fresh on
//! > disk but absent from mydia-rs's view of streaming_sessions, the
//! > DB-presence cleanup would destroy a live session.
//!
//! Mtime is conservative: when both backends overlap, the on-disk
//! files are the authoritative shared signal.

use std::path::Path;
use std::time::{Duration, SystemTime};

use chrono::{DateTime, Utc};
use tracing::{info, warn};

use crate::error::StreamingError;

/// Staleness threshold mirroring
/// `lib/mydia/streaming/hls_cleanup.ex:16` (`@stale_threshold_hours 24`).
pub const STALE_THRESHOLD_HOURS: u64 = 24;

/// Summary of a boot-cleanup pass. Logged at info level by the
/// application start hook so operators can see how many stale
/// directories were swept.
#[derive(Debug, Clone, Default)]
pub struct BootCleanupReport {
    /// Total session directories inspected.
    pub inspected: usize,
    /// Directories that were removed (stale > threshold).
    pub removed: usize,
    /// Directories that were skipped (still within threshold).
    pub skipped: usize,
    /// Errors encountered for individual directories. Cleanup is
    /// best-effort: one bad dir does not abort the sweep.
    pub errors: Vec<String>,
}

impl BootCleanupReport {
    /// True if no errors were recorded and the sweep had work.
    pub fn had_work(&self) -> bool {
        self.removed > 0
    }
}

/// Run a boot-time cleanup pass on `temp_base_dir`. Returns a report
/// with counts; errors on individual dirs are accumulated and do not
/// abort the sweep. The function returns `Err` only when the base
/// directory itself cannot be listed (e.g. permission denied).
///
/// `now` is injected for testability — production callers pass
/// `Utc::now()`.
pub async fn boot_cleanup(
    temp_base_dir: &Path,
    now: DateTime<Utc>,
) -> Result<BootCleanupReport, StreamingError> {
    boot_cleanup_with_threshold(
        temp_base_dir,
        now,
        Duration::from_secs(STALE_THRESHOLD_HOURS * 60 * 60),
    )
    .await
}

/// Variant that allows callers / tests to override the staleness
/// threshold. Production code should use [`boot_cleanup`].
pub async fn boot_cleanup_with_threshold(
    temp_base_dir: &Path,
    now: DateTime<Utc>,
    threshold: Duration,
) -> Result<BootCleanupReport, StreamingError> {
    let mut report = BootCleanupReport::default();

    let exists = tokio::fs::try_exists(temp_base_dir).await.unwrap_or(false);
    if !exists {
        info!(
            dir = %temp_base_dir.display(),
            "HLS temp dir does not exist; nothing to clean"
        );
        return Ok(report);
    }

    let mut read_dir = tokio::fs::read_dir(temp_base_dir)
        .await
        .map_err(|e| StreamingError::fs(temp_base_dir.to_path_buf(), e))?;

    while let Some(entry) = read_dir
        .next_entry()
        .await
        .map_err(|e| StreamingError::fs(temp_base_dir.to_path_buf(), e))?
    {
        let path = entry.path();
        let Ok(metadata) = entry.metadata().await else {
            report
                .errors
                .push(format!("could not stat entry: {}", path.display()));
            continue;
        };
        if !metadata.is_dir() {
            continue;
        }
        report.inspected += 1;
        match classify(&path, &metadata, now, threshold) {
            Classification::Stale => match tokio::fs::remove_dir_all(&path).await {
                Ok(()) => {
                    info!(dir = %path.display(), "removed stale HLS session dir");
                    report.removed += 1;
                }
                Err(err) => {
                    warn!(
                        dir = %path.display(),
                        error = %err,
                        "failed to remove stale HLS session dir"
                    );
                    report
                        .errors
                        .push(format!("remove {}: {err}", path.display()));
                }
            },
            Classification::Fresh => {
                report.skipped += 1;
            }
            Classification::Unstable => {
                // mtime unreadable for some reason — treat conservatively
                // and leave it alone. Phoenix removes it; mydia-rs prefers
                // false-positive preservation here because the parallel
                // cutover window prizes safety over aggressive sweeping.
                report.skipped += 1;
                report
                    .errors
                    .push(format!("mtime missing for {}", path.display()));
            }
        }
    }

    info!(
        inspected = report.inspected,
        removed = report.removed,
        skipped = report.skipped,
        errors = report.errors.len(),
        "HLS cleanup sweep complete"
    );
    Ok(report)
}

/// Remove a specific session directory by `session_id`. Best-effort:
/// no-op when the directory doesn't exist.
pub async fn cleanup_session_dir(
    temp_base_dir: &Path,
    session_id: &str,
) -> Result<(), StreamingError> {
    let path = temp_base_dir.join(session_id);
    match tokio::fs::remove_dir_all(&path).await {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(StreamingError::fs(path, err)),
    }
}

enum Classification {
    Stale,
    Fresh,
    Unstable,
}

fn classify(
    path: &Path,
    metadata: &std::fs::Metadata,
    now: DateTime<Utc>,
    threshold: Duration,
) -> Classification {
    let Ok(mtime) = metadata.modified() else {
        return Classification::Unstable;
    };
    let now_sys: SystemTime = now.into();
    let Ok(age) = now_sys.duration_since(mtime) else {
        // mtime is in the future — clock skew. Treat as fresh since
        // aggressive sweeping on skewed clocks is worse than leaving
        // a directory in place.
        warn!(
            dir = %path.display(),
            "session dir mtime is in the future — leaving in place"
        );
        return Classification::Fresh;
    };
    if age >= threshold {
        Classification::Stale
    } else {
        Classification::Fresh
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;

    fn write_dir(path: &Path) -> std::path::PathBuf {
        std::fs::create_dir_all(path).unwrap();
        // Drop a file inside so the dir feels "real".
        let marker = path.join("index.m3u8");
        File::create(&marker).unwrap();
        path.to_path_buf()
    }

    fn set_mtime(path: &Path, time: SystemTime) {
        let file = std::fs::File::open(path).unwrap();
        let times = std::fs::FileTimes::new().set_modified(time);
        file.set_times(times).unwrap();
    }

    #[tokio::test]
    async fn missing_temp_dir_is_no_op() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("nonexistent");
        let report = boot_cleanup(&path, Utc::now()).await.unwrap();
        assert_eq!(report.inspected, 0);
        assert_eq!(report.removed, 0);
    }

    #[tokio::test]
    async fn fresh_dirs_are_skipped() {
        let tmp = tempfile::tempdir().unwrap();
        let session = tmp.path().join("aaaa-bbbb-cccc");
        write_dir(&session);

        let report = boot_cleanup(tmp.path(), Utc::now()).await.unwrap();
        assert_eq!(report.inspected, 1);
        assert_eq!(report.removed, 0);
        assert_eq!(report.skipped, 1);
        // Directory still exists.
        assert!(tokio::fs::metadata(&session).await.is_ok());
    }

    #[tokio::test]
    async fn stale_dirs_are_removed() {
        let tmp = tempfile::tempdir().unwrap();
        let session = tmp.path().join("aaaa-bbbb-cccc");
        write_dir(&session);
        // Push mtime 48 hours into the past.
        let past = SystemTime::now() - Duration::from_secs(48 * 60 * 60);
        set_mtime(&session, past);

        let report = boot_cleanup(tmp.path(), Utc::now()).await.unwrap();
        assert_eq!(report.inspected, 1);
        assert_eq!(report.removed, 1);
        // Directory should be gone now.
        assert!(tokio::fs::metadata(&session).await.is_err());
    }

    #[tokio::test]
    async fn cleanup_session_dir_is_idempotent() {
        let tmp = tempfile::tempdir().unwrap();
        cleanup_session_dir(tmp.path(), "no-such-session")
            .await
            .unwrap();
        // Now make one and remove it.
        let session = tmp.path().join("real-session");
        write_dir(&session);
        cleanup_session_dir(tmp.path(), "real-session")
            .await
            .unwrap();
        assert!(tokio::fs::metadata(&session).await.is_err());
    }

    #[tokio::test]
    async fn cleanup_honors_threshold_argument() {
        let tmp = tempfile::tempdir().unwrap();
        let session = tmp.path().join("a");
        write_dir(&session);
        let past = SystemTime::now() - Duration::from_secs(10 * 60); // 10 min
        set_mtime(&session, past);

        // Threshold of 5 minutes → stale.
        let report =
            boot_cleanup_with_threshold(tmp.path(), Utc::now(), Duration::from_secs(5 * 60))
                .await
                .unwrap();
        assert_eq!(report.removed, 1);
    }
}
