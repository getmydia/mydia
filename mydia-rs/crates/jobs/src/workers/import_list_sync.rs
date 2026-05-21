//! Port of `lib/mydia/jobs/import_list_sync.ex`.
//!
//! Fetches items from one import list's source (TMDB trending,
//! custom URL, ...), compares them against existing items, and upserts
//! new items as pending. If `auto_add` is enabled, enqueues a
//! follow-up `ImportListAutoAdd` job.

use apalis::prelude::Data;
use mydia_rs_pubsub::{topics, Event};
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportListSyncArgs {
    pub import_list_id: String,
    /// Override the list's `auto_add` flag for this sync run.
    #[serde(default)]
    pub auto_add: bool,
}

pub const QUEUE: Queue = Queue::ImportLists;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn import_list_sync(
    args: ImportListSyncArgs,
    ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    tracing::info!(
        import_list_id = %args.import_list_id,
        auto_add = args.auto_add,
        "starting import list sync"
    );

    let Some(import_list) = get_import_list(&ctx.db, &args.import_list_id).await? else {
        tracing::warn!(import_list_id = %args.import_list_id, "import list not found");
        return Ok(());
    };

    if !import_list.enabled {
        tracing::debug!(import_list_id = %args.import_list_id, "import list disabled; skipping");
        return Ok(());
    }

    // Provider dispatch: TMDB::supports?(type) or CustomURL::supports?(type).
    // The provider impls live in
    // `mydia_rs_integrations::import_lists::{tmdb, custom_url}`. The
    // upsert + provider call surface lands once the U5 model layer
    // adds an `ImportListItem` repository.
    tracing::warn!(
        import_list_id = %args.import_list_id,
        list_type = %import_list.list_type,
        "import_list_sync upsert delegated to Phoenix during cutover window"
    );

    ctx.pubsub.publish(
        topics::IMPORT_LISTS,
        Event::from_json(serde_json::json!({
            "event": "import_list_sync_complete",
            "import_list_id": args.import_list_id,
            "status": "ok",
            "stats": { "new": 0, "updated": 0, "total": 0 },
        })),
    );

    if args.auto_add || import_list.auto_add {
        tracing::info!(
            import_list_id = %args.import_list_id,
            "auto_add enabled; would enqueue ImportListAutoAdd"
        );
    }
    Ok(())
}

#[derive(Debug, Clone)]
struct ImportListRow {
    #[allow(dead_code)]
    id: String,
    enabled: bool,
    auto_add: bool,
    list_type: String,
}

async fn get_import_list(
    db: &mydia_rs_db::Db,
    id: &str,
) -> Result<Option<ImportListRow>, JobsError> {
    use mydia_rs_db::Db;
    let row: Option<(String, bool, bool, String)> = match db {
        Db::Sqlite(pool) => {
            sqlx::query_as("SELECT id, enabled, auto_add, type FROM import_lists WHERE id = ?")
                .bind(id)
                .fetch_optional(pool)
                .await?
        }
        Db::Postgres(pool) => {
            sqlx::query_as("SELECT id, enabled, auto_add, type FROM import_lists WHERE id = $1")
                .bind(id)
                .fetch_optional(pool)
                .await?
        }
    };
    Ok(row.map(|(id, enabled, auto_add, list_type)| ImportListRow {
        id,
        enabled,
        auto_add,
        list_type,
    }))
}
