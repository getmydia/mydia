//! Recursive directory traversal — Rust port of
//! `lib/mydia/library/scanner.ex`.
//!
//! Uses `walkdir` (sync) inside a `tokio::task::spawn_blocking` so a
//! large library scan does not stall the async runtime. Per-batch
//! progress is published on the `library_scanner` `PubSub` topic from
//! [`mydia_rs_pubsub::topics::LIBRARY_SCANNER`].

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use chrono::{DateTime, Utc};
use mydia_rs_pubsub::{topics, Event, Pubsub};
use serde::{Deserialize, Serialize};
use walkdir::WalkDir;

use crate::error::LibraryError;

/// Extension lists per Phoenix `Mydia.Library.Scanner`'s
/// `@video_extensions` / `@music_extensions` / `@book_extensions`.
/// Lowercase, with leading dot.
const VIDEO_EXTENSIONS: &[&str] = &[
    ".mkv", ".mp4", ".avi", ".mov", ".wmv", ".flv", ".webm", ".m4v", ".mpg", ".mpeg", ".m2ts",
    ".ts",
];
const MUSIC_EXTENSIONS: &[&str] = &[
    ".mp3", ".flac", ".wav", ".aac", ".ogg", ".m4a", ".wma", ".opus", ".ape", ".alac", ".aiff",
];
const BOOK_EXTENSIONS: &[&str] = &[
    ".epub", ".pdf", ".mobi", ".azw", ".azw3", ".cbr", ".cbz", ".djvu", ".fb2", ".lit", ".txt",
    ".rtf",
];
const IMAGE_EXTENSIONS: &[&str] = &[".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp"];

/// Library kind — drives the extension allowlist.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LibraryKind {
    Movies,
    Series,
    Mixed,
    Music,
    Books,
    Adult,
}

impl LibraryKind {
    #[must_use]
    pub fn extensions(self) -> Vec<&'static str> {
        match self {
            Self::Movies | Self::Series | Self::Mixed => VIDEO_EXTENSIONS.to_vec(),
            Self::Music => MUSIC_EXTENSIONS.to_vec(),
            Self::Books => BOOK_EXTENSIONS.to_vec(),
            Self::Adult => {
                let mut v = VIDEO_EXTENSIONS.to_vec();
                v.extend_from_slice(IMAGE_EXTENSIONS);
                v
            }
        }
    }
}

/// Options for [`Scanner::scan`].
#[derive(Clone)]
pub struct ScanOptions {
    /// Whether to descend into subdirectories.
    pub recursive: bool,
    /// Allowed file extensions (lowercase, leading dot). When
    /// `None`, `LibraryKind::Mixed` is used.
    pub extensions: Option<Vec<String>>,
    /// `PubSub` bus to broadcast progress events through. `None`
    /// disables event emission (useful for tests).
    pub pubsub: Option<Pubsub>,
    /// Emit a progress event every `progress_interval` files. `0`
    /// disables progress reporting; default 100 matches Phoenix.
    pub progress_interval: usize,
    /// Optional caller-supplied scan id, attached to every progress
    /// event so subscribers can multiplex scans for the same path.
    pub scan_id: Option<String>,
}

impl std::fmt::Debug for ScanOptions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ScanOptions")
            .field("recursive", &self.recursive)
            .field("extensions", &self.extensions)
            .field("pubsub_attached", &self.pubsub.is_some())
            .field("progress_interval", &self.progress_interval)
            .field("scan_id", &self.scan_id)
            .finish()
    }
}

impl Default for ScanOptions {
    fn default() -> Self {
        Self {
            recursive: true,
            extensions: None,
            pubsub: None,
            progress_interval: 100,
            scan_id: None,
        }
    }
}

/// Per-file scan result.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanFile {
    pub path: PathBuf,
    pub size: u64,
    pub modified_at: DateTime<Utc>,
    pub filename: String,
    pub directory: PathBuf,
    pub extension: String,
}

/// Whole-scan result.
#[derive(Debug, Clone, Default)]
pub struct ScanResult {
    pub files: Vec<ScanFile>,
    pub total_size: u64,
    pub errors: Vec<ScanError>,
}

/// Per-entry error encountered during a scan. Not fatal — the scan
/// continues and the error is appended here, matching Phoenix.
#[derive(Debug, Clone)]
pub struct ScanError {
    pub path: PathBuf,
    pub message: String,
}

/// Progress / lifecycle events published on the
/// [`mydia_rs_pubsub::topics::LIBRARY_SCANNER`] topic.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum ScanProgressEvent {
    Started {
        scan_id: Option<String>,
        path: PathBuf,
    },
    Progress {
        scan_id: Option<String>,
        path: PathBuf,
        files_found: usize,
    },
    Completed {
        scan_id: Option<String>,
        path: PathBuf,
        files_found: usize,
        errors: usize,
    },
    Failed {
        scan_id: Option<String>,
        path: PathBuf,
        reason: String,
    },
}

/// Public facade.
#[derive(Debug, Default, Clone, Copy)]
pub struct Scanner;

impl Scanner {
    /// Scan `directory`.
    ///
    /// Heavy lifting runs inside `spawn_blocking` so the async
    /// runtime stays responsive during a long traversal.
    pub async fn scan(
        directory: impl AsRef<Path>,
        opts: ScanOptions,
    ) -> Result<ScanResult, LibraryError> {
        let dir = directory.as_ref().to_path_buf();
        validate_directory(&dir)?;

        if let Some(bus) = &opts.pubsub {
            broadcast(
                bus,
                &ScanProgressEvent::Started {
                    scan_id: opts.scan_id.clone(),
                    path: dir.clone(),
                },
            );
        }

        let extensions = opts.extensions.clone().unwrap_or_else(|| {
            LibraryKind::Mixed
                .extensions()
                .iter()
                .map(|&s| s.to_owned())
                .collect()
        });
        let recursive = opts.recursive;
        let progress_interval = opts.progress_interval;
        let scan_id = opts.scan_id.clone();
        let pubsub = opts.pubsub.clone();
        let dir_for_block = dir.clone();

        let result = tokio::task::spawn_blocking(move || {
            walk_dir(
                &dir_for_block,
                recursive,
                &extensions,
                progress_interval,
                scan_id.as_deref(),
                pubsub.as_ref(),
            )
        })
        .await
        .map_err(|e| LibraryError::Io {
            path: dir.display().to_string(),
            source: std::io::Error::other(format!("scan task failed: {e}")),
        })?;

        if let Some(bus) = &opts.pubsub {
            broadcast(
                bus,
                &ScanProgressEvent::Completed {
                    scan_id: opts.scan_id.clone(),
                    path: dir.clone(),
                    files_found: result.files.len(),
                    errors: result.errors.len(),
                },
            );
        }

        Ok(result)
    }
}

fn validate_directory(path: &Path) -> Result<(), LibraryError> {
    let meta = std::fs::symlink_metadata(path).map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => LibraryError::NotFound(path.display().to_string()),
        std::io::ErrorKind::PermissionDenied => {
            LibraryError::PermissionDenied(path.display().to_string())
        }
        _ => LibraryError::Io {
            path: path.display().to_string(),
            source: e,
        },
    })?;

    // Resolve symlinks for the directory test.
    let is_dir = if meta.file_type().is_symlink() {
        std::fs::metadata(path).map(|m| m.is_dir()).unwrap_or(false)
    } else {
        meta.is_dir()
    };

    if !is_dir {
        return Err(LibraryError::NotADirectory(path.display().to_string()));
    }
    Ok(())
}

fn walk_dir(
    root: &Path,
    recursive: bool,
    extensions: &[String],
    progress_interval: usize,
    scan_id: Option<&str>,
    pubsub: Option<&Pubsub>,
) -> ScanResult {
    let max_depth = if recursive { usize::MAX } else { 1 };

    let mut result = ScanResult::default();
    let walker = WalkDir::new(root)
        .follow_links(true)
        .max_depth(max_depth)
        .into_iter();

    let mut emitted_progress = 0usize;

    for entry in walker {
        let entry = match entry {
            Ok(e) => e,
            Err(err) => {
                let path = err
                    .path()
                    .map_or_else(|| root.to_path_buf(), Path::to_path_buf);
                result.errors.push(ScanError {
                    path,
                    message: err.to_string(),
                });
                continue;
            }
        };

        if entry.file_type().is_dir() {
            continue;
        }
        if !entry.file_type().is_file() && !entry.file_type().is_symlink() {
            continue;
        }

        let path = entry.path();
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| format!(".{}", e.to_lowercase()))
            .unwrap_or_default();
        if ext.is_empty() || !extensions.iter().any(|allowed| allowed == &ext) {
            continue;
        }

        let metadata = match entry.metadata() {
            Ok(m) => m,
            Err(err) => {
                result.errors.push(ScanError {
                    path: path.to_path_buf(),
                    message: err.to_string(),
                });
                continue;
            }
        };

        let size = metadata.len();
        let modified_at: DateTime<Utc> = metadata
            .modified()
            .ok()
            .and_then(|t| {
                t.duration_since(SystemTime::UNIX_EPOCH).ok().and_then(|d| {
                    let secs = i64::try_from(d.as_secs()).ok()?;
                    DateTime::<Utc>::from_timestamp(secs, d.subsec_nanos())
                })
            })
            .unwrap_or_else(Utc::now);

        let filename = path
            .file_name()
            .and_then(|n| n.to_str())
            .map(str::to_owned)
            .unwrap_or_default();
        let directory = path.parent().map(Path::to_path_buf).unwrap_or_default();

        result.total_size = result.total_size.saturating_add(size);
        result.files.push(ScanFile {
            path: path.to_path_buf(),
            size,
            modified_at,
            filename,
            directory,
            extension: ext,
        });

        if progress_interval > 0 && result.files.len() - emitted_progress >= progress_interval {
            emitted_progress = result.files.len();
            if let Some(bus) = pubsub {
                broadcast(
                    bus,
                    &ScanProgressEvent::Progress {
                        scan_id: scan_id.map(str::to_owned),
                        path: root.to_path_buf(),
                        files_found: emitted_progress,
                    },
                );
            }
        }
    }

    result
}

fn broadcast(bus: &Pubsub, event: &ScanProgressEvent) {
    if let Ok(payload) = Event::from_serializable(event) {
        bus.publish(topics::LIBRARY_SCANNER, payload);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn write(dir: &Path, name: &str, content: &str) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, content).unwrap();
        path
    }

    #[tokio::test]
    async fn scan_returns_video_files() {
        let dir = TempDir::new().unwrap();
        write(dir.path(), "Movie.2020.1080p.mkv", "hi");
        write(dir.path(), "ignore.txt", "skip");
        let result = Scanner::scan(dir.path(), ScanOptions::default())
            .await
            .unwrap();
        assert_eq!(result.files.len(), 1);
        assert!(result.errors.is_empty());
    }

    #[tokio::test]
    async fn scan_descends_recursively() {
        let dir = TempDir::new().unwrap();
        let sub = dir.path().join("sub");
        std::fs::create_dir(&sub).unwrap();
        write(&sub, "Show.S01E01.mkv", "x");
        let result = Scanner::scan(dir.path(), ScanOptions::default())
            .await
            .unwrap();
        assert_eq!(result.files.len(), 1);
    }

    #[tokio::test]
    async fn scan_empty_dir_is_ok() {
        let dir = TempDir::new().unwrap();
        let result = Scanner::scan(dir.path(), ScanOptions::default())
            .await
            .unwrap();
        assert!(result.files.is_empty());
        assert!(result.errors.is_empty());
    }

    #[tokio::test]
    async fn scan_rejects_missing_path() {
        let err = Scanner::scan("/nonexistent/path/xyz", ScanOptions::default())
            .await
            .unwrap_err();
        assert!(matches!(err, LibraryError::NotFound(_)));
    }

    #[tokio::test]
    async fn scan_broadcasts_progress_events() {
        let dir = TempDir::new().unwrap();
        for i in 0..3 {
            write(dir.path(), &format!("Movie.{i}.1080p.mkv"), "hi");
        }
        let bus = Pubsub::new();
        let mut rx = bus.subscribe(topics::LIBRARY_SCANNER);
        let opts = ScanOptions {
            pubsub: Some(bus.clone()),
            progress_interval: 1,
            scan_id: Some("test-scan".into()),
            ..ScanOptions::default()
        };
        let result = Scanner::scan(dir.path(), opts).await.unwrap();
        assert_eq!(result.files.len(), 3);
        // At least a started + progress + completed event.
        let mut events = Vec::new();
        while let Ok(event) = rx.try_recv() {
            events.push(event);
        }
        assert!(!events.is_empty());
    }
}
