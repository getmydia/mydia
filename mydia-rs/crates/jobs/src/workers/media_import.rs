//! Port of `lib/mydia/jobs/media_import.ex` (~1845 LOC in Phoenix).
//!
//! Imports a completed download into the library: hardlinks (preferred,
//! when on same filesystem), moves, or copies the files into their
//! organized target paths, creates the `media_files` rows, and
//! optionally removes the source from the download client.
//!
//! ## Operation priority
//!
//! 1. Hardlink (instant, no duplicate storage) — requires same fs.
//! 2. Move — when `use_hardlinks=false` and `move_files=true`.
//! 3. Copy — default, safest.
//!
//! The full import path (file ops, organizer, NFO write, indexer
//! notify, media-server notify) lives across several building-block
//! crates (`library::FileOrganizer`, `library::FileAnalyzer`,
//! `integrations::media_server::Notifier`, `metadata::NfoWriter`). The
//! Rust port wires these together inside `import_download` — most of
//! which is parked behind the U5 model layer for the parallel-window
//! cutover.

use apalis::prelude::Data;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaImportArgs {
    pub download_id: String,
    /// Files selected for import. Each entry is the per-download
    /// metadata payload Phoenix attaches to the Oban job; the Rust
    /// port preserves the shape verbatim so cross-backend reads work.
    #[serde(default)]
    pub target_files: Option<serde_json::Value>,
    #[serde(default)]
    pub save_path: Option<String>,
    #[serde(default)]
    pub snooze_count: u32,
    #[serde(default = "default_true")]
    pub use_hardlinks: bool,
    #[serde(default)]
    pub move_files: bool,
    #[serde(default)]
    pub rename_files: bool,
}

const fn default_true() -> bool {
    true
}

pub const QUEUE: Queue = Queue::Default;
/// Phoenix uses `max_attempts: 1000` with a custom backoff schedule.
/// apalis's retry layer handles exponential backoff via the `Retry`
/// middleware; the `WorkerBuilder` registers a retry policy at wire-up
/// time so the per-worker constant is just the upper bound.
pub const MAX_ATTEMPTS: u32 = 1000;

pub async fn media_import(args: MediaImportArgs, _ctx: Data<AppContext>) -> Result<(), JobsError> {
    tracing::info!(
        download_id = %args.download_id,
        snooze_count = args.snooze_count,
        use_hardlinks = args.use_hardlinks,
        move_files = args.move_files,
        rename_files = args.rename_files,
        "starting media import"
    );

    // The full import pipeline is the largest single worker in the
    // codebase. It needs:
    //
    // - `downloads` row fetch (idempotency guard on `imported_at`)
    // - `library_path` resolution
    // - `FileOrganizer` for target-path computation
    // - `FileAnalyzer` for ffprobe metadata
    // - `media_files` row insert
    // - NFO sidecar write (via `metadata::NfoWriter`)
    // - Media-server notify (Plex/Jellyfin via `integrations`)
    // - Optional client-side removal of the source torrent/nzb
    //
    // Several of those building blocks are parked behind the U5 model
    // layer for cutover. The worker shape, args contract, and queue
    // assignment are wire-compatible with Phoenix so the parallel
    // window observes apalis-shaped jobs landing — and the existing
    // Phoenix worker continues to do the heavy lifting until the U5
    // layer is in place.
    tracing::warn!(
        download_id = %args.download_id,
        "media_import pipeline delegated to Phoenix during cutover window"
    );
    Ok(())
}
