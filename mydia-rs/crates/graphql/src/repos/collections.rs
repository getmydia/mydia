//! Port of the `Mydia.Collections` context slice the favorites mutation
//! consumes.
//!
//! Phoenix stores favorites as a system Collection (a row in
//! `collections` with `is_system = true` and `name = "Favorites"`)
//! plus rows in `collection_items` pointing at media items. Mirrored
//! here exactly so favorite state round-trips between Phoenix and
//! mydia-rs without a migration.
//!
//! Behavior follows `lib/mydia/collections.ex:250-270` —
//! `toggle_favorite/2` lazily creates the user's Favorites collection
//! on first use, then either inserts or deletes the membership row.
//!
//! Post-U13 cutover: SeaORM-native. Writes go through
//! `insert_active_model` so the wrapper-typed `id` / `user_id` /
//! `media_item_id` / `inserted_at` columns get the right Postgres
//! casts. Reads use vanilla `Entity::find()`.

use chrono::Utc;
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_entities::{collection_items, collections};
use sea_orm::entity::prelude::*;
use sea_orm::query::QuerySelect;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{ActiveValue, DatabaseConnection, Set};
use uuid::Uuid;

/// Outcome of `toggle_favorite`. Mirrors Phoenix's
/// `{:ok, :added | :removed}` return.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToggleOutcome {
    Added,
    Removed,
}

/// Return the user's Favorites collection ID, creating it lazily if
/// necessary. Phoenix's `get_or_create_favorites/1` matches by
/// `(user_id, is_system = true, name = "Favorites")`.
async fn get_or_create_favorites(
    db: &DatabaseConnection,
    user_id: &str,
) -> Result<UuidText, DbErr> {
    let user_uuid = Uuid::parse_str(user_id)
        .map(UuidText::from)
        .map_err(|err| DbErr::Custom(err.to_string()))?;
    let backend = db.get_database_backend();

    let existing = collections::Entity::find()
        .filter(Expr::col(collections::Column::UserId).eq(user_uuid.into_simple_expr(backend)))
        .filter(collections::Column::IsSystem.eq(true))
        .filter(collections::Column::Name.eq("Favorites".to_owned()))
        .limit(1)
        .one(db)
        .await?;

    if let Some(row) = existing {
        return Ok(row.id);
    }

    let new_id = UuidText::new_v4();
    let now = DateTimeSecs::from(Utc::now());
    let am = collections::ActiveModel {
        id: Set(new_id),
        user_id: Set(user_uuid),
        name: Set("Favorites".to_owned()),
        description: ActiveValue::NotSet,
        r#type: Set("manual".to_owned()),
        poster_path: ActiveValue::NotSet,
        sort_order: Set("position".to_owned()),
        smart_rules: ActiveValue::NotSet,
        visibility: Set("private".to_owned()),
        is_system: Set(true),
        position: Set(0),
        inserted_at: Set(now),
        updated_at: Set(now),
    };
    let _ = mydia_rs_db::insert_active_model(am, db).await?;
    Ok(new_id)
}

async fn find_favorite_item(
    db: &DatabaseConnection,
    collection_id: UuidText,
    media_item_id: &str,
) -> Result<Option<collection_items::Model>, DbErr> {
    let media_uuid = Uuid::parse_str(media_item_id)
        .map(UuidText::from)
        .map_err(|err| DbErr::Custom(err.to_string()))?;
    let backend = db.get_database_backend();
    collection_items::Entity::find()
        .filter(
            Expr::col(collection_items::Column::CollectionId)
                .eq(collection_id.into_simple_expr(backend)),
        )
        .filter(
            Expr::col(collection_items::Column::MediaItemId)
                .eq(media_uuid.into_simple_expr(backend)),
        )
        .one(db)
        .await
}

/// Toggle a media item's membership in the user's Favorites
/// collection. Returns the outcome for the GraphQL response.
pub async fn toggle_favorite(
    db: &DatabaseConnection,
    user_id: &str,
    media_item_id: &str,
) -> Result<ToggleOutcome, DbErr> {
    let collection_id = get_or_create_favorites(db, user_id).await?;
    let existing = find_favorite_item(db, collection_id, media_item_id).await?;
    let backend = db.get_database_backend();

    if let Some(item) = existing {
        collection_items::Entity::delete_many()
            .filter(
                Expr::col(collection_items::Column::Id).eq(item.id.into_simple_expr(backend)),
            )
            .exec(db)
            .await?;
        return Ok(ToggleOutcome::Removed);
    }

    let item_id = UuidText::new_v4();
    let now = DateTimeSecs::from(Utc::now());
    let media_uuid = Uuid::parse_str(media_item_id)
        .map(UuidText::from)
        .map_err(|err| DbErr::Custom(err.to_string()))?;
    let am = collection_items::ActiveModel {
        id: Set(item_id),
        collection_id: Set(collection_id),
        media_item_id: Set(media_uuid),
        position: Set(0),
        inserted_at: Set(now),
    };
    let _ = mydia_rs_db::insert_active_model(am, db).await?;
    Ok(ToggleOutcome::Added)
}
