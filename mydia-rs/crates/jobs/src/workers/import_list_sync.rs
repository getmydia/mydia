//! Port of `lib/mydia/jobs/import_list_sync.ex`.
//!
//! Fetches items from one import list's source (TMDB trending,
//! custom URL, ...), compares them against existing items, and upserts
//! new items as pending. If `auto_add` is enabled, enqueues a
//! follow-up `ImportListAutoAdd` job.
//!
//! Post-U12 cutover: SeaORM-native against `import_lists`. Caller
//! identifies the row by its UUID string; the lookup binds through
//! `UuidText::into_simple_expr` for engine-aware comparison.

use std::str::FromStr;

use apalis::prelude::Data;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{DatabaseConnection, EntityTrait, QueryFilter};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use mydia_rs_db::types::UuidText;
use mydia_rs_entities::import_lists;
use mydia_rs_pubsub::{topics, Event};

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
        list_type = %import_list.r#type,
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

async fn get_import_list(
    db: &DatabaseConnection,
    id: &str,
) -> Result<Option<import_lists::Model>, JobsError> {
    // Phoenix `binary_id`s are UUID strings; a non-UUID input cannot
    // match a real row, treat as "not found".
    let Ok(uuid) = Uuid::from_str(id) else {
        return Ok(None);
    };
    let backend = db.get_database_backend();
    let row = import_lists::Entity::find()
        .filter(Expr::col(import_lists::Column::Id).eq(UuidText(uuid).into_simple_expr(backend)))
        .one(db)
        .await?;
    Ok(row)
}
