//! Port of `lib/mydia/jobs/media_reclassify.ex`.
//!
//! Re-runs the category classifier on every `media_item` belonging to a
//! library path. Reclassification updates category metadata in place;
//! file paths are not touched.

use apalis::prelude::Data;
use mydia_rs_pubsub::{topics, Event};
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaReclassifyArgs {
    pub library_path_id: String,
}

pub const QUEUE: Queue = Queue::Media;
pub const MAX_ATTEMPTS: u32 = 1;

pub async fn media_reclassify(
    args: MediaReclassifyArgs,
    ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    let start = std::time::Instant::now();
    tracing::info!(library_path_id = %args.library_path_id, "starting media reclassification");

    ctx.pubsub.publish(
        topics::LIBRARY_SCANNER,
        Event::from_json(serde_json::json!({
            "event": "media_reclassify_started",
            "library_path_id": args.library_path_id,
        })),
    );

    // The classifier lives in `Mydia.Media.Classifier` (Phoenix). The
    // Rust building-block port is parked behind the U5 model layer —
    // for U17 we keep the worker shape wire-compatible and let Phoenix
    // continue to do the actual reclassification during the parallel
    // window.
    tracing::warn!(
        library_path_id = %args.library_path_id,
        "media_reclassify delegated to Phoenix during cutover window"
    );

    let elapsed_ms = start.elapsed().as_millis();
    tracing::info!(
        library_path_id = %args.library_path_id,
        duration_ms = elapsed_ms,
        "media reclassification completed (delegated)"
    );

    ctx.pubsub.publish(
        topics::LIBRARY_SCANNER,
        Event::from_json(serde_json::json!({
            "event": "media_reclassify_completed",
            "library_path_id": args.library_path_id,
            "total": 0,
            "updated": 0,
            "skipped": 0,
            "unchanged": 0,
        })),
    );
    Ok(())
}
