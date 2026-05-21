//! Port of `lib/mydia/jobs/import_list_auto_add.ex`.
//!
//! Reads every `import_list_items` row of an import list that hasn't
//! been added yet, runs metadata-relay search to resolve the canonical
//! provider id, creates the matching `media_items` row, and marks the
//! import-list-item as added.

use apalis::prelude::Data;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportListAutoAddArgs {
    pub import_list_id: String,
}

pub const QUEUE: Queue = Queue::ImportLists;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn import_list_auto_add(
    args: ImportListAutoAddArgs,
    _ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    tracing::info!(
        import_list_id = %args.import_list_id,
        "starting import-list auto-add"
    );

    // The flow:
    // 1. Read every `import_list_items` row of this list where
    //    `added_at IS NULL` and the item is `pending`.
    // 2. For each item, search metadata-relay by `tmdb_id` (`media_type`
    //    drives which endpoint).
    // 3. Create / upsert the resulting `media_items` row.
    // 4. Mark `added_at = now` on the import-list-item.
    //
    // The metadata side uses `mydia_rs_metadata::Relay::search(...)`
    // already; the write half waits on the U5 model layer.
    tracing::warn!(
        import_list_id = %args.import_list_id,
        "import_list_auto_add delegated to Phoenix during cutover window"
    );
    Ok(())
}
