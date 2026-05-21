//! Port of `lib/mydia/jobs/library_reorganize.ex`.
//!
//! Moves existing media files into their category-appropriate paths
//! when `auto_organize` is enabled on a library path. The actual file
//! moves live in the building-block crate's `FileOrganizer` (not yet
//! ported — Phoenix `lib/mydia/library/file_organizer.ex`); the worker
//! here owns the orchestration and the pubsub progress events.

use apalis::prelude::Data;
use mydia_rs_pubsub::{topics, Event};
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryReorganizeArgs {
    pub library_path_id: String,
}

pub const QUEUE: Queue = Queue::Media;
pub const MAX_ATTEMPTS: u32 = 1;

pub async fn library_reorganize(
    args: LibraryReorganizeArgs,
    ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    let start = std::time::Instant::now();
    tracing::info!(library_path_id = %args.library_path_id, "starting library reorganization");

    ctx.pubsub.publish(
        topics::LIBRARY_SCANNER,
        Event::from_json(serde_json::json!({
            "event": "library_reorganize_started",
            "library_path_id": args.library_path_id,
        })),
    );

    // The Phoenix `FileOrganizer.reorganize_library/1` walks every
    // `media_file` row of the library path and moves the underlying
    // file to the destination computed from category metadata. The
    // building-block port lands alongside the U5 model layer — until
    // then the worker emits the start/completed pubsub events so the
    // admin LiveView UI continues to function during the parallel
    // window.
    tracing::warn!(
        library_path_id = %args.library_path_id,
        "library_reorganize file moves delegated to Phoenix during cutover window"
    );

    let elapsed_ms = start.elapsed().as_millis();
    tracing::info!(
        library_path_id = %args.library_path_id,
        duration_ms = elapsed_ms,
        "library reorganization completed (delegated)"
    );

    ctx.pubsub.publish(
        topics::LIBRARY_SCANNER,
        Event::from_json(serde_json::json!({
            "event": "library_reorganize_completed",
            "library_path_id": args.library_path_id,
            "total": 0,
            "moved": 0,
            "skipped": 0,
            "errors": 0,
        })),
    );
    Ok(())
}
