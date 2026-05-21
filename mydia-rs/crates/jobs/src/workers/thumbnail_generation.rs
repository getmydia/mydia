//! Port of `lib/mydia/jobs/thumbnail_generation.ex`.
//!
//! Generates thumbnails (static cover image), and optionally sprite
//! sheets + VTT (for hover-scrub) and video preview clips from media
//! files. Three modes:
//!
//! - `"single"` — one file by id.
//! - `"batch"` — explicit list of `media_file` ids.
//! - `"missing"` — sweep every row whose `thumbnail_at IS NULL`.

use apalis::prelude::Data;
use mydia_rs_pubsub::{topics, Event};
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

pub const DEFAULT_BATCH_SIZE: usize = 10;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ThumbnailGenerationArgs {
    /// `"single"`, `"batch"`, or `"missing"`. Defaults to `"single"`
    /// when `media_file_id` is set, otherwise `"missing"`.
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub media_file_id: Option<String>,
    #[serde(default)]
    pub media_file_ids: Option<Vec<String>>,
    #[serde(default)]
    pub library_path_id: Option<String>,
    #[serde(default)]
    pub include_sprites: bool,
    #[serde(default)]
    pub include_previews: bool,
    #[serde(default)]
    pub batch_size: Option<usize>,
}

pub const QUEUE: Queue = Queue::Media;
pub const MAX_ATTEMPTS: u32 = 5;

pub async fn thumbnail_generation(
    args: ThumbnailGenerationArgs,
    ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    let mode = args.mode.as_deref().unwrap_or_else(|| {
        if args.media_file_id.is_some() {
            "single"
        } else {
            "missing"
        }
    });

    tracing::info!(
        mode,
        media_file_id = args.media_file_id.as_deref().unwrap_or(""),
        library_path_id = args.library_path_id.as_deref().unwrap_or(""),
        include_sprites = args.include_sprites,
        include_previews = args.include_previews,
        "starting thumbnail generation"
    );

    ctx.pubsub.publish(
        topics::THUMBNAIL_GENERATION,
        Event::from_json(serde_json::json!({
            "event": "generation_started",
            "mode": mode,
        })),
    );

    // The actual `ThumbnailGenerator`, `SpriteGenerator`, and
    // `PreviewGenerator` are FFmpeg-driven building blocks; their Rust
    // ports live alongside the library crate but the row-state writes
    // (`thumbnail_path`, `thumbnail_at`, sprite paths, preview paths)
    // depend on the U5 model layer. Wired through to Phoenix during
    // the parallel window.
    tracing::warn!(
        mode,
        "thumbnail_generation delegated to Phoenix during cutover window"
    );

    ctx.pubsub.publish(
        topics::THUMBNAIL_GENERATION,
        Event::from_json(serde_json::json!({
            "event": "generation_completed",
            "mode": mode,
            "processed": 0,
        })),
    );
    Ok(())
}
