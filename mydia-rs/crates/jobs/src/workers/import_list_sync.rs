//! Port of `lib/mydia/jobs/import_list_sync.ex`.
//!
//! Fetches items from one import list's source (TMDB trending,
//! custom URL, ...), compares them against existing items, and upserts
//! new items as pending. If `auto_add` is enabled, enqueues a
//! follow-up `ImportListAutoAdd` job.

use std::str::FromStr;
use std::sync::Arc;

use apalis::prelude::Data;
use chrono::Utc;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{ColumnTrait, DatabaseConnection, EntityTrait, QueryFilter, Set};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_entities::{import_list_items, import_lists, media_items};
use mydia_rs_integrations::import_lists::{
    CustomUrlProvider, ImportListProvider, ImportListSpec, TmdbProvider,
};
use mydia_rs_pubsub::{topics, Event};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::{JobStorage, JobsError};
use crate::workers::import_list_auto_add::ImportListAutoAddArgs;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportListSyncArgs {
    pub import_list_id: String,
    #[serde(default)]
    pub auto_add: bool,
}

pub const QUEUE: Queue = Queue::ImportLists;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn import_list_sync(
    args: ImportListSyncArgs,
    ctx: Data<AppContext>,
    auto_add_storage: Data<Arc<tokio::sync::Mutex<JobStorage<ImportListAutoAddArgs>>>>,
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

    let spec = ImportListSpec {
        list_type: import_list.r#type.clone(),
        media_type: import_list.media_type.clone(),
        config: import_list
            .config
            .as_ref()
            .map(|jm| jm.0.clone())
            .unwrap_or_default(),
    };

    let tmdb = TmdbProvider::new("https://relay.mydia.dev").unwrap_or_else(|e| {
        tracing::error!(error = %e, "failed to construct TmdbProvider; using dummy");
        TmdbProvider::new("http://localhost").unwrap()
    });
    let custom = CustomUrlProvider::new().unwrap_or_else(|e| {
        tracing::error!(error = %e, "failed to construct CustomUrlProvider; using dummy");
        CustomUrlProvider::new().unwrap()
    });

    let items = if tmdb.supports(&spec.list_type) {
        tmdb.fetch_items(&spec)
            .await
            .map_err(|e| JobsError::WorkerError(format!("tmdb fetch failed: {e}")))?
    } else {
        custom
            .fetch_items(&spec)
            .await
            .map_err(|e| JobsError::WorkerError(format!("custom url fetch failed: {e}")))?
    };

    let mut new_count = 0u32;
    let mut updated_count = 0u32;

    for item in &items {
        // Check for duplicate against existing media_items by tmdb_id.
        if find_media_item_by_tmdb(&ctx.db, item.tmdb_id)
            .await
            .is_some()
        {
            upsert_import_list_item(
                &ctx.db,
                &import_list.id,
                item.tmdb_id,
                &item.title,
                item.year,
                item.poster_path.as_deref(),
                "added",
            )
            .await?;
            updated_count += 1;
        } else {
            upsert_import_list_item(
                &ctx.db,
                &import_list.id,
                item.tmdb_id,
                &item.title,
                item.year,
                item.poster_path.as_deref(),
                "pending",
            )
            .await?;
            new_count += 1;
        }
    }

    // Stamp last_synced_at.
    let backend = ctx.db.get_database_backend();
    let now = DateTimeSecs::from(Utc::now());
    import_lists::Entity::update_many()
        .col_expr(
            import_lists::Column::LastSyncedAt,
            now.into_simple_expr(backend),
        )
        .col_expr(
            import_lists::Column::UpdatedAt,
            now.into_simple_expr(backend),
        )
        .col_expr(
            import_lists::Column::SyncError,
            Expr::value(Option::<String>::None),
        )
        .filter(Expr::col(import_lists::Column::Id).eq(import_list.id.into_simple_expr(backend)))
        .exec(&ctx.db)
        .await?;

    ctx.pubsub.publish(
        topics::IMPORT_LISTS,
        Event::from_json(serde_json::json!({
            "event": "import_list_sync_complete",
            "import_list_id": args.import_list_id,
            "status": "ok",
            "stats": { "new": new_count, "updated": updated_count, "total": new_count + updated_count },
        })),
    );

    if args.auto_add || import_list.auto_add {
        auto_add_storage
            .lock()
            .await
            .push(ImportListAutoAddArgs {
                import_list_id: args.import_list_id.clone(),
            })
            .await?;
    }

    Ok(())
}

async fn get_import_list(
    db: &DatabaseConnection,
    id: &str,
) -> Result<Option<import_lists::Model>, JobsError> {
    let Ok(uuid) = Uuid::from_str(id) else {
        return Ok(None);
    };
    let backend = db.get_database_backend();
    import_lists::Entity::find()
        .filter(Expr::col(import_lists::Column::Id).eq(UuidText(uuid).into_simple_expr(backend)))
        .one(db)
        .await
        .map_err(JobsError::Db)
}

async fn find_media_item_by_tmdb(
    db: &DatabaseConnection,
    tmdb_id: i64,
) -> Option<media_items::Model> {
    media_items::Entity::find()
        .filter(media_items::Column::TmdbId.eq(tmdb_id))
        .one(db)
        .await
        .ok()
        .flatten()
}

async fn upsert_import_list_item(
    db: &DatabaseConnection,
    import_list_id: &UuidText,
    tmdb_id: i64,
    title: &str,
    year: Option<i32>,
    poster_path: Option<&str>,
    status: &str,
) -> Result<(), JobsError> {
    let backend = db.get_database_backend();
    let now = DateTimeSecs::from(Utc::now());

    // Check if exists.
    let existing = import_list_items::Entity::find()
        .filter(
            Expr::col(import_list_items::Column::ImportListId)
                .eq((*import_list_id).into_simple_expr(backend)),
        )
        .filter(import_list_items::Column::TmdbId.eq(tmdb_id as i32))
        .one(db)
        .await?;

    if let Some(row) = existing {
        // Update title/year/poster if changed.
        let am = import_list_items::ActiveModel {
            id: sea_orm::Unchanged(row.id),
            title: Set(title.to_owned()),
            year: Set(year),
            poster_path: Set(poster_path.map(str::to_owned)),
            updated_at: Set(now),
            ..Default::default()
        };
        mydia_rs_db::update_active_model(am, db).await?;
    } else {
        let am = import_list_items::ActiveModel {
            id: Set(UuidText(Uuid::new_v4())),
            import_list_id: Set(*import_list_id),
            tmdb_id: Set(tmdb_id as i32),
            title: Set(title.to_owned()),
            year: Set(year),
            poster_path: Set(poster_path.map(str::to_owned)),
            status: Set(status.to_owned()),
            discovered_at: Set(now),
            inserted_at: Set(now),
            updated_at: Set(now),
            ..Default::default()
        };
        mydia_rs_db::insert_active_model(am, db).await?;
    }
    Ok(())
}
