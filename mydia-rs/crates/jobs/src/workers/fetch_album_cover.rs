//! Port of `lib/mydia/jobs/fetch_album_cover.ex`.
//!
//! Fetches the cover image for one music album. Priority:
//!
//! 1. Cover Art Archive (when the album row has a `MusicBrainz` id) via
//!    the metadata-relay's music endpoint.
//! 2. Embedded art extracted from the first available track file.

use apalis::prelude::Data;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FetchAlbumCoverArgs {
    pub album_id: String,
}

pub const QUEUE: Queue = Queue::Media;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn fetch_album_cover(
    args: FetchAlbumCoverArgs,
    _ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    tracing::info!(album_id = %args.album_id, "fetching album cover");

    // The cover-fetch flow needs:
    // - `albums` row lookup (`musicbrainz_id`, `track_ids`)
    // - `MusicRelay::get_cover_art(...)` for the CAA path
    // - `CoverExtractor` for the embedded-art path
    // - `GeneratedMedia` write to persist the resulting blob
    //
    // The building blocks for the CAA path live in
    // `mydia_rs_metadata::MusicRelay`; the embedded-art extractor lives
    // alongside the library crate. The album row write requires the
    // U5 model layer, so the full flow is delegated to Phoenix during
    // the parallel window.
    tracing::warn!(
        album_id = %args.album_id,
        "fetch_album_cover delegated to Phoenix during cutover window"
    );
    Ok(())
}
