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

use chrono::Utc;
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_db::Db;
use sqlx::FromRow;
use uuid::Uuid;

/// Outcome of `toggle_favorite`. Mirrors Phoenix's
/// `{:ok, :added | :removed}` return.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToggleOutcome {
    Added,
    Removed,
}

#[derive(Debug, Clone, FromRow)]
struct CollectionRow {
    pub id: UuidText,
}

#[derive(Debug, Clone, FromRow)]
struct CollectionItemRow {
    #[allow(dead_code)]
    pub id: UuidText,
}

/// Return the user's Favorites collection ID, creating it lazily if
/// necessary. Phoenix's `get_or_create_favorites/1` matches by
/// `(user_id, is_system = true, name = "Favorites")`.
async fn get_or_create_favorites(db: &Db, user_id: &str) -> Result<UuidText, sqlx::Error> {
    let user_uuid = Uuid::parse_str(user_id)
        .map(UuidText::from)
        .map_err(|_| sqlx::Error::RowNotFound)?;
    let select_sql = "SELECT id FROM collections \
                      WHERE user_id = $1 AND is_system = $2 AND name = $3 \
                      LIMIT 1";

    let existing = match db {
        Db::Sqlite(pool) => {
            let sql = select_sql
                .replace("$1", "?")
                .replace("$2", "?")
                .replace("$3", "?");
            sqlx::query_as::<_, CollectionRow>(&sql)
                .bind(user_uuid)
                .bind(true)
                .bind("Favorites")
                .fetch_optional(pool)
                .await?
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, CollectionRow>(select_sql)
                .bind(user_uuid)
                .bind(true)
                .bind("Favorites")
                .fetch_optional(pool)
                .await?
        }
    };

    if let Some(row) = existing {
        return Ok(row.id);
    }

    let new_id = UuidText::new_v4();
    let now = DateTimeSecs::from(Utc::now());
    match db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "INSERT INTO collections \
                 (id, user_id, name, type, sort_order, visibility, is_system, position, \
                  inserted_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(new_id)
            .bind(user_uuid)
            .bind("Favorites")
            .bind("manual")
            .bind("position")
            .bind("private")
            .bind(true)
            .bind(0i32)
            .bind(now)
            .bind(now)
            .execute(pool)
            .await?;
        }
        Db::Postgres(pool) => {
            sqlx::query(
                "INSERT INTO collections \
                 (id, user_id, name, type, sort_order, visibility, is_system, position, \
                  inserted_at, updated_at) \
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
            )
            .bind(new_id)
            .bind(user_uuid)
            .bind("Favorites")
            .bind("manual")
            .bind("position")
            .bind("private")
            .bind(true)
            .bind(0i32)
            .bind(now)
            .bind(now)
            .execute(pool)
            .await?;
        }
    }
    Ok(new_id)
}

async fn find_favorite_item(
    db: &Db,
    collection_id: UuidText,
    media_item_id: &str,
) -> Result<Option<CollectionItemRow>, sqlx::Error> {
    let media_uuid = Uuid::parse_str(media_item_id)
        .map(UuidText::from)
        .map_err(|_| sqlx::Error::RowNotFound)?;
    let sql = "SELECT id FROM collection_items \
               WHERE collection_id = $1 AND media_item_id = $2";
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?").replace("$2", "?");
            sqlx::query_as::<_, CollectionItemRow>(&sql)
                .bind(collection_id)
                .bind(media_uuid)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, CollectionItemRow>(sql)
                .bind(collection_id)
                .bind(media_uuid)
                .fetch_optional(pool)
                .await
        }
    }
}

/// Toggle a media item's membership in the user's Favorites
/// collection. Returns the outcome for the GraphQL response.
pub async fn toggle_favorite(
    db: &Db,
    user_id: &str,
    media_item_id: &str,
) -> Result<ToggleOutcome, sqlx::Error> {
    let collection_id = get_or_create_favorites(db, user_id).await?;
    let existing = find_favorite_item(db, collection_id, media_item_id).await?;

    if let Some(item) = existing {
        let item_id = item.id.0.to_string();
        match db {
            Db::Sqlite(pool) => {
                sqlx::query("DELETE FROM collection_items WHERE id = ?")
                    .bind(&item_id)
                    .execute(pool)
                    .await?;
            }
            Db::Postgres(pool) => {
                sqlx::query("DELETE FROM collection_items WHERE id = $1")
                    .bind(&item_id)
                    .execute(pool)
                    .await?;
            }
        }
        return Ok(ToggleOutcome::Removed);
    }

    let item_id = UuidText::new_v4();
    let now = DateTimeSecs::from(Utc::now());
    let media_uuid = Uuid::parse_str(media_item_id)
        .map(UuidText::from)
        .map_err(|_| sqlx::Error::RowNotFound)?;
    match db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "INSERT INTO collection_items \
                 (id, collection_id, media_item_id, position, inserted_at) \
                 VALUES (?, ?, ?, ?, ?)",
            )
            .bind(item_id)
            .bind(collection_id)
            .bind(media_uuid)
            .bind(0i32)
            .bind(now)
            .execute(pool)
            .await?;
        }
        Db::Postgres(pool) => {
            sqlx::query(
                "INSERT INTO collection_items \
                 (id, collection_id, media_item_id, position, inserted_at) \
                 VALUES ($1, $2, $3, $4, $5)",
            )
            .bind(item_id)
            .bind(collection_id)
            .bind(media_uuid)
            .bind(0i32)
            .bind(now)
            .execute(pool)
            .await?;
        }
    }
    Ok(ToggleOutcome::Added)
}
