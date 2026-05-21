//! Port of `Mydia.Collections` query slice — list / get / item enumeration.
//!
//! Mutations (toggle_favorite) live in [`super::collections`]; this
//! module is the read-side. Smart collections (Phoenix's
//! `Collections.SmartRules` evaluator) are not ported yet — U14
//! returns empty item lists for `type = "smart"` and notes the gap.

use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_db::Db;
use mydia_rs_models::MediaItem;
use serde_json::Value;
use sqlx::FromRow;
use uuid::Uuid;

#[derive(Debug, Clone, FromRow)]
pub struct CollectionRow {
    pub id: UuidText,
    pub name: String,
    pub description: Option<String>,
    pub r#type: String,
    pub visibility: String,
    pub is_system: bool,
    pub position: i32,
    pub user_id: UuidText,
    pub inserted_at: DateTimeSecs,
    pub updated_at: DateTimeSecs,
}

const COLUMNS: &str = "id, name, description, type, visibility, is_system, position, user_id, \
     inserted_at, updated_at";

pub async fn list_collections_for_user(
    db: &Db,
    user_id: &str,
) -> Result<Vec<CollectionRow>, sqlx::Error> {
    let user_uuid = Uuid::parse_str(user_id)
        .map(UuidText::from)
        .map_err(|_| sqlx::Error::RowNotFound)?;
    let sql = format!(
        "SELECT {COLUMNS} FROM collections WHERE user_id = $1 ORDER BY position ASC, name ASC"
    );
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, CollectionRow>(&sql)
                .bind(user_uuid)
                .fetch_all(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, CollectionRow>(&sql)
                .bind(user_uuid)
                .fetch_all(pool)
                .await
        }
    }
}

pub async fn get_collection_by_id(
    db: &Db,
    user_id: &str,
    id: &str,
) -> Result<Option<CollectionRow>, sqlx::Error> {
    let user_uuid = Uuid::parse_str(user_id)
        .map(UuidText::from)
        .map_err(|_| sqlx::Error::RowNotFound)?;
    let row_uuid = Uuid::parse_str(id)
        .map(UuidText::from)
        .map_err(|_| sqlx::Error::RowNotFound)?;
    let sql = format!("SELECT {COLUMNS} FROM collections WHERE user_id = $1 AND id = $2");
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?").replace("$2", "?");
            sqlx::query_as::<_, CollectionRow>(&sql)
                .bind(user_uuid)
                .bind(row_uuid)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, CollectionRow>(&sql)
                .bind(user_uuid)
                .bind(row_uuid)
                .fetch_optional(pool)
                .await
        }
    }
}

pub async fn item_count(db: &Db, collection_id: UuidText) -> Result<i64, sqlx::Error> {
    let sql = "SELECT COUNT(*) FROM collection_items WHERE collection_id = $1";
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_scalar(&sql)
                .bind(collection_id)
                .fetch_one(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_scalar(sql)
                .bind(collection_id)
                .fetch_one(pool)
                .await
        }
    }
}

const MEDIA_ITEM_COLUMNS: &str =
    "mi.id, mi.type, mi.title, mi.original_title, mi.year, mi.tmdb_id, mi.tvdb_id, \
     mi.imdb_id, mi.metadata, mi.monitored, mi.monitoring_preset, mi.category, \
     mi.category_override, mi.seasons_refreshed_at, mi.quality_profile_id, \
     mi.inserted_at, mi.updated_at";

pub async fn list_items(
    db: &Db,
    collection_id: UuidText,
    limit: i64,
) -> Result<Vec<MediaItem>, sqlx::Error> {
    let sql = format!(
        "SELECT {MEDIA_ITEM_COLUMNS} FROM collection_items ci \
         JOIN media_items mi ON ci.media_item_id = mi.id \
         WHERE ci.collection_id = $1 \
         ORDER BY ci.position ASC \
         LIMIT $2"
    );
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?").replace("$2", "?");
            sqlx::query_as::<_, MediaItem>(&sql)
                .bind(collection_id)
                .bind(limit)
                .fetch_all(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, MediaItem>(&sql)
                .bind(collection_id)
                .bind(limit)
                .fetch_all(pool)
                .await
        }
    }
}

/// Up to `count` poster paths from the first items in a collection.
/// Used to build the collection cover collage on the Phoenix side.
pub async fn poster_paths(
    db: &Db,
    collection_id: UuidText,
    count: i64,
) -> Result<Vec<String>, sqlx::Error> {
    let rows = list_items(db, collection_id, count).await?;
    let posters = rows
        .iter()
        .filter_map(|row| {
            row.metadata
                .as_ref()
                .and_then(|m| m.0.get("poster_path"))
                .and_then(Value::as_str)
                .map(|s| s.to_owned())
        })
        .collect();
    Ok(posters)
}
