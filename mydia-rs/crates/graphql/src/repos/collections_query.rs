//! Port of `Mydia.Collections` query slice — list / get / item enumeration.
//!
//! Mutations (`toggle_favorite`) live in [`super::collections`]; this
//! module is the read-side. Smart collections (Phoenix's
//! `Collections.SmartRules` evaluator) are not ported yet — U14
//! returns empty item lists for `type = "smart"` and notes the gap.
//!
//! Post-U13 cutover: SeaORM-native.

use mydia_rs_db::types::UuidText;
use mydia_rs_entities::{collection_items, collections, media_items};
use sea_orm::entity::prelude::*;
use sea_orm::query::{QueryOrder, QuerySelect};
use sea_orm::sea_query::{Expr, ExprTrait, JoinType};
use sea_orm::DatabaseConnection;
use serde_json::Value;
use uuid::Uuid;

pub async fn list_collections_for_user(
    db: &DatabaseConnection,
    user_id: &str,
) -> Result<Vec<collections::Model>, DbErr> {
    let Ok(uuid) = Uuid::parse_str(user_id) else {
        return Ok(Vec::new());
    };
    let wrapper = UuidText::from(uuid);
    let backend = db.get_database_backend();
    collections::Entity::find()
        .filter(Expr::col(collections::Column::UserId).eq(wrapper.into_simple_expr(backend)))
        .order_by_asc(collections::Column::Position)
        .order_by_asc(collections::Column::Name)
        .all(db)
        .await
}

pub async fn get_collection_by_id(
    db: &DatabaseConnection,
    user_id: &str,
    id: &str,
) -> Result<Option<collections::Model>, DbErr> {
    let Ok(user_uuid) = Uuid::parse_str(user_id) else {
        return Ok(None);
    };
    let Ok(row_uuid) = Uuid::parse_str(id) else {
        return Ok(None);
    };
    let user_wrapper = UuidText::from(user_uuid);
    let row_wrapper = UuidText::from(row_uuid);
    let backend = db.get_database_backend();
    collections::Entity::find()
        .filter(Expr::col(collections::Column::UserId).eq(user_wrapper.into_simple_expr(backend)))
        .filter(Expr::col(collections::Column::Id).eq(row_wrapper.into_simple_expr(backend)))
        .one(db)
        .await
}

pub async fn item_count(db: &DatabaseConnection, collection_id: UuidText) -> Result<i64, DbErr> {
    let backend = db.get_database_backend();
    let count = collection_items::Entity::find()
        .filter(
            Expr::col(collection_items::Column::CollectionId)
                .eq(collection_id.into_simple_expr(backend)),
        )
        .count(db)
        .await?;
    Ok(count as i64)
}

pub async fn list_items(
    db: &DatabaseConnection,
    collection_id: UuidText,
    limit: i64,
) -> Result<Vec<media_items::Model>, DbErr> {
    let backend = db.get_database_backend();
    // SELECT media_items.* FROM collection_items
    //   JOIN media_items ON collection_items.media_item_id = media_items.id
    //  WHERE collection_items.collection_id = $1
    //  ORDER BY collection_items.position ASC
    //  LIMIT $2
    media_items::Entity::find()
        .join_rev(
            JoinType::InnerJoin,
            collection_items::Relation::MediaItems.def(),
        )
        .filter(
            Expr::col((
                collection_items::Entity,
                collection_items::Column::CollectionId,
            ))
            .eq(collection_id.into_simple_expr(backend)),
        )
        .order_by_asc(Expr::col((
            collection_items::Entity,
            collection_items::Column::Position,
        )))
        .limit(limit as u64)
        .all(db)
        .await
}

/// Up to `count` poster paths from the first items in a collection.
/// Used to build the collection cover collage on the Phoenix side.
pub async fn poster_paths(
    db: &DatabaseConnection,
    collection_id: UuidText,
    count: i64,
) -> Result<Vec<String>, DbErr> {
    let rows = list_items(db, collection_id, count).await?;
    // `media_items.metadata` is `Option<String>` (text-holding-JSON on
    // both engines per the entity annotation). Parse each value lazily
    // so an empty or invalid payload contributes no poster.
    let posters = rows
        .iter()
        .filter_map(|row| {
            let raw = row.metadata.as_deref()?;
            let value: Value = serde_json::from_str(raw).ok()?;
            value
                .get("poster_path")
                .and_then(Value::as_str)
                .map(std::borrow::ToOwned::to_owned)
        })
        .collect();
    Ok(posters)
}
