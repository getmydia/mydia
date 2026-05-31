//! Port of `lib/mydia/jobs/import_list_auto_add.ex`.
//!
//! Reads every `import_list_items` row of an import list that hasn't
//! been added yet, runs metadata-relay search to resolve the canonical
//! provider id, creates the matching `media_items` row, and marks the
//! import-list-item as added.

use std::str::FromStr;

use apalis::prelude::Data;
use chrono::Utc;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{ColumnTrait, DatabaseConnection, EntityTrait, QueryFilter, Set};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_entities::{import_list_items, import_lists, media_items};
use mydia_rs_metadata::{FetchOpts, MediaType};

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
    ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    tracing::info!(
        import_list_id = %args.import_list_id,
        "starting import-list auto-add"
    );

    let Some(import_list) = get_import_list(&ctx.db, &args.import_list_id).await? else {
        tracing::warn!(import_list_id = %args.import_list_id, "import list not found");
        return Ok(());
    };

    let pending = fetch_pending_items(&ctx.db, &import_list.id).await?;
    tracing::info!(count = pending.len(), "pending import list items");

    if pending.is_empty() {
        return Ok(());
    }

    let media_type = match import_list.media_type.as_str() {
        "tv_show" => MediaType::TvShow,
        _ => MediaType::Movie,
    };

    // Resolve a provider from the registry for metadata enrichment.
    let provider = match ctx
        .metadata
        .get("metadata_relay")
        .or_else(|| ctx.metadata.get("tmdb"))
    {
        Some(reg) => reg.adapter.clone(),
        None => {
            return Err(JobsError::WorkerError(
                "no metadata provider configured in registry".into(),
            ));
        }
    };
    let provider_config = ctx
        .metadata
        .get("metadata_relay")
        .or_else(|| ctx.metadata.get("tmdb"))
        .map_or_else(
            mydia_rs_metadata::ProviderConfig::metadata_relay_default,
            |r| r.config.clone(),
        );

    for item in &pending {
        // Check for duplicate media_item by tmdb_id.
        if let Some(existing) = find_media_item_by_tmdb(&ctx.db, i64::from(item.tmdb_id)).await {
            mark_item_added(&ctx.db, &item.id, &existing.id).await?;
            continue;
        }

        // Fetch full metadata.
        let fetch_opts = FetchOpts {
            media_type: Some(media_type),
            language: Some("en-US".into()),
            ..FetchOpts::default()
        };

        match provider
            .fetch_by_id(&provider_config, &item.tmdb_id.to_string(), &fetch_opts)
            .await
        {
            Ok(metadata) => {
                let mi_id = UuidText(Uuid::new_v4());
                let now = DateTimeSecs::from(Utc::now());

                let am = media_items::ActiveModel {
                    id: Set(mi_id),
                    r#type: Set(import_list.media_type.clone()),
                    title: Set(metadata.title.unwrap_or_else(|| item.title.clone())),
                    year: Set(metadata.year.or(item.year)),
                    tmdb_id: Set(Some(item.tmdb_id)),
                    tvdb_id: Set(None),
                    monitored: Set(Some(true)),
                    monitoring_preset: Set(Some("all".into())),
                    quality_profile_id: Set(import_list.quality_profile_id),
                    category: Set(None),
                    inserted_at: Set(now),
                    updated_at: Set(now),
                    ..Default::default()
                };
                mydia_rs_db::insert_active_model(am, &ctx.db).await?;
                mark_item_added(&ctx.db, &item.id, &mi_id).await?;
            }
            Err(e) => {
                tracing::warn!(
                    tmdb_id = item.tmdb_id,
                    error = %e,
                    "metadata fetch failed for import list item"
                );
                mark_item_failed(&ctx.db, &item.id, &format!("metadata fetch failed: {e}")).await?;
            }
        }
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

async fn fetch_pending_items(
    db: &DatabaseConnection,
    import_list_id: &UuidText,
) -> Result<Vec<import_list_items::Model>, JobsError> {
    let backend = db.get_database_backend();
    import_list_items::Entity::find()
        .filter(
            Expr::col(import_list_items::Column::ImportListId)
                .eq((*import_list_id).into_simple_expr(backend)),
        )
        .filter(import_list_items::Column::Status.eq("pending"))
        .all(db)
        .await
        .map_err(JobsError::Db)
}

async fn find_media_item_by_tmdb(
    db: &DatabaseConnection,
    tmdb_id: i64,
) -> Option<media_items::Model> {
    media_items::Entity::find()
        .filter(media_items::Column::TmdbId.eq(tmdb_id as i32))
        .one(db)
        .await
        .ok()
        .flatten()
}

async fn mark_item_added(
    db: &DatabaseConnection,
    item_id: &UuidText,
    media_item_id: &UuidText,
) -> Result<(), JobsError> {
    let backend = db.get_database_backend();
    let now = DateTimeSecs::from(Utc::now());
    import_list_items::Entity::update_many()
        .col_expr(import_list_items::Column::Status, Expr::value("added"))
        .col_expr(
            import_list_items::Column::MediaItemId,
            (*media_item_id).into_simple_expr(backend),
        )
        .col_expr(
            import_list_items::Column::UpdatedAt,
            now.into_simple_expr(backend),
        )
        .filter(Expr::col(import_list_items::Column::Id).eq((*item_id).into_simple_expr(backend)))
        .exec(db)
        .await?;
    Ok(())
}

async fn mark_item_failed(
    db: &DatabaseConnection,
    item_id: &UuidText,
    reason: &str,
) -> Result<(), JobsError> {
    let backend = db.get_database_backend();
    let now = DateTimeSecs::from(Utc::now());
    import_list_items::Entity::update_many()
        .col_expr(import_list_items::Column::Status, Expr::value("failed"))
        .col_expr(
            import_list_items::Column::SkipReason,
            Expr::value(reason.to_owned()),
        )
        .col_expr(
            import_list_items::Column::UpdatedAt,
            now.into_simple_expr(backend),
        )
        .filter(Expr::col(import_list_items::Column::Id).eq((*item_id).into_simple_expr(backend)))
        .exec(db)
        .await?;
    Ok(())
}
