//! Port of the slice of `Mydia.Media` that the browse + discovery +
//! media resolvers consume. Each function targets a specific resolver
//! call site; expand as new resolvers come online.
//!
//! Post-U13 cutover: `SeaORM`-native. The dialect-divergent `Db` enum is
//! gone; every read returns the entity's `Model` and resolvers shape
//! those into the GraphQL surface. Wrapper-typed columns (`id`, `*_at`)
//! route their bind through `into_simple_expr(backend)` so Postgres
//! gets the `::uuid` / `::timestamptz` cast and `SQLite` gets the plain
//! TEXT bind.
//!
//! The canonical pattern documented in U13 is [`list_media_items`]:
//! dynamic filters via `Condition::all().add_option(...)`, the
//! `COLLATE NOCASE` → `lower(title)` parity break for ordering, and
//! sub-query `IN` membership via `Query::select`.

use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_entities::{episodes, media_files, media_items};
use sea_orm::entity::prelude::*;
use sea_orm::query::{QueryOrder, QuerySelect};
use sea_orm::sea_query::{Condition, Expr, ExprTrait, Func, Query, SimpleExpr};
use sea_orm::DatabaseConnection;
use uuid::Uuid;

/// Filter set the browse resolvers apply. Mirrors the keyword opts
/// `Mydia.Media.list_media_items/1` accepts.
#[derive(Debug, Default, Clone)]
pub struct ListMediaItemsOpts<'a> {
    pub kind: Option<&'a str>,
    pub category: Option<&'a str>,
    /// When `true`, restricts to media items that have at least one
    /// associated `media_files` row (either via `media_item_id` or
    /// via an episode). Mirrors `filter_by_has_files/1`.
    pub has_files: bool,
    /// When set, restricts to rows whose `inserted_at` is at or after
    /// the given datetime (RFC3339 string). Used by the discovery
    /// "recently added" rail to apply the 30-day window.
    pub added_since: Option<&'a str>,
    /// Case-insensitive substring search across `title`. Mirrors
    /// `Mydia.Media.list_media_items(search: term)` at
    /// `lib/mydia/media.ex:1557` — `LIKE` against `lower(title)`.
    pub search: Option<&'a str>,
}

/// Parse a `&str` UUID into the wrapper. Invalid input maps to `None`
/// so callers can treat that as "no rows match" without raising a
/// driver-level error.
fn parse_uuid(s: &str) -> Option<UuidText> {
    Uuid::parse_str(s).ok().map(UuidText::from)
}

/// Parse an RFC3339 datetime string into the `DateTimeSecs` wrapper.
fn parse_added_since(s: &str) -> Option<DateTimeSecs> {
    chrono::DateTime::parse_from_rfc3339(s)
        .map(|dt| DateTimeSecs::from(dt.with_timezone(&chrono::Utc)))
        .ok()
}

/// List media items, ordered by title ASC. Pagination and sort
/// happen in-memory in the resolver, mirroring Phoenix today (the
/// resolver `list_movies` fetches all, sorts, slices).
///
/// **Key Decision parity break (documented):** Phoenix's
/// `ORDER BY title COLLATE NOCASE ASC` becomes `ORDER BY lower(title) ASC`
/// for both engines — `SeaORM`'s typed builder cannot express `SQLite`'s
/// `COLLATE NOCASE`, and `lower()` is the engine-portable equivalent
/// the rest of the workspace uses.
pub async fn list_media_items(
    db: &DatabaseConnection,
    opts: &ListMediaItemsOpts<'_>,
) -> Result<Vec<media_items::Model>, DbErr> {
    let backend = db.get_database_backend();
    let mut q = media_items::Entity::find();

    let mut cond = Condition::all();
    if let Some(kind) = opts.kind {
        cond = cond.add(media_items::Column::Type.eq(kind.to_owned()));
    }
    if let Some(category) = opts.category {
        cond = cond.add(media_items::Column::Category.eq(category.to_owned()));
    }
    if opts.has_files {
        // `id IN (SELECT media_item_id FROM media_files WHERE media_item_id IS NOT NULL)
        //  OR id IN (SELECT e.media_item_id FROM media_files mf
        //            JOIN episodes e ON mf.episode_id = e.id)`
        let direct_files = Query::select()
            .column(media_files::Column::MediaItemId)
            .from(media_files::Entity)
            .and_where(media_files::Column::MediaItemId.is_not_null())
            .to_owned();
        let via_episodes = Query::select()
            .column((episodes::Entity, episodes::Column::MediaItemId))
            .from(media_files::Entity)
            .inner_join(
                episodes::Entity,
                Expr::col((media_files::Entity, media_files::Column::EpisodeId))
                    .equals((episodes::Entity, episodes::Column::Id)),
            )
            .to_owned();
        cond = cond.add(
            Condition::any()
                .add(Expr::col(media_items::Column::Id).in_subquery(direct_files))
                .add(Expr::col(media_items::Column::Id).in_subquery(via_episodes)),
        );
    }
    if let Some(since) = opts.added_since {
        if let Some(dt) = parse_added_since(since) {
            cond = cond
                .add(Expr::col(media_items::Column::InsertedAt).gte(dt.into_simple_expr(backend)));
        }
    }
    if let Some(term) = opts.search {
        let pattern = format!("%{}%", term.to_lowercase());
        cond =
            cond.add(Expr::expr(Func::lower(Expr::col(media_items::Column::Title))).like(pattern));
    }

    q = q.filter(cond);
    let lower_title: SimpleExpr = Func::lower(Expr::col(media_items::Column::Title)).into();
    q.order_by(lower_title, sea_orm::Order::Asc).all(db).await
}

/// Fetch one media item by UUID. Returns `Ok(None)` when the row
/// doesn't exist (resolvers translate to a GraphQL "not found"
/// error).
pub async fn get_media_item(
    db: &DatabaseConnection,
    id: &str,
) -> Result<Option<media_items::Model>, DbErr> {
    let Some(wrapper) = parse_uuid(id) else {
        return Ok(None);
    };
    let backend = db.get_database_backend();
    media_items::Entity::find()
        .filter(Expr::col(media_items::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .one(db)
        .await
}

/// Fetch one episode by UUID.
pub async fn get_episode(
    db: &DatabaseConnection,
    id: &str,
) -> Result<Option<episodes::Model>, DbErr> {
    let Some(wrapper) = parse_uuid(id) else {
        return Ok(None);
    };
    let backend = db.get_database_backend();
    episodes::Entity::find()
        .filter(Expr::col(episodes::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .one(db)
        .await
}

/// List episodes for a given media item, ordered by season then
/// episode number.
pub async fn list_episodes(
    db: &DatabaseConnection,
    media_item_id: &str,
) -> Result<Vec<episodes::Model>, DbErr> {
    let Some(wrapper) = parse_uuid(media_item_id) else {
        return Ok(Vec::new());
    };
    let backend = db.get_database_backend();
    episodes::Entity::find()
        .filter(Expr::col(episodes::Column::MediaItemId).eq(wrapper.into_simple_expr(backend)))
        .order_by_asc(episodes::Column::SeasonNumber)
        .order_by_asc(episodes::Column::EpisodeNumber)
        .all(db)
        .await
}

/// Whether at least one media file exists for the given episode.
/// Used by `get_season` to determine the `has_files` flag.
pub async fn episode_has_files(db: &DatabaseConnection, episode_id: &str) -> Result<bool, DbErr> {
    let Some(wrapper) = parse_uuid(episode_id) else {
        return Ok(false);
    };
    let backend = db.get_database_backend();
    let count = media_files::Entity::find()
        .filter(Expr::col(media_files::Column::EpisodeId).eq(wrapper.into_simple_expr(backend)))
        .limit(1)
        .count(db)
        .await?;
    Ok(count > 0)
}

/// List media files for a media item (movies — episode-less files).
#[allow(dead_code)]
pub async fn list_media_files_for_movie(
    db: &DatabaseConnection,
    media_item_id: &str,
) -> Result<Vec<media_files::Model>, DbErr> {
    let Some(wrapper) = parse_uuid(media_item_id) else {
        return Ok(Vec::new());
    };
    let backend = db.get_database_backend();
    media_files::Entity::find()
        .filter(Expr::col(media_files::Column::MediaItemId).eq(wrapper.into_simple_expr(backend)))
        .filter(media_files::Column::EpisodeId.is_null())
        .filter(media_files::Column::TrashedAt.is_null())
        .order_by_asc(media_files::Column::InsertedAt)
        .all(db)
        .await
}

/// Fetch a single media file by ID. Used by the streaming resolvers
/// to resolve `file_id` arguments to a `MediaFile` row before
/// computing candidates or starting a session.
pub async fn get_media_file(
    db: &DatabaseConnection,
    id: &str,
) -> Result<Option<media_files::Model>, DbErr> {
    let Some(wrapper) = parse_uuid(id) else {
        return Ok(None);
    };
    let backend = db.get_database_backend();
    media_files::Entity::find()
        .filter(Expr::col(media_files::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .one(db)
        .await
}

/// Fetch the first media file associated with a media item (used for
/// `streamingCandidates(contentType: "movie", id: ...)` lookup).
pub async fn first_media_file_for_movie(
    db: &DatabaseConnection,
    media_item_id: &str,
) -> Result<Option<media_files::Model>, DbErr> {
    let Some(wrapper) = parse_uuid(media_item_id) else {
        return Ok(None);
    };
    let backend = db.get_database_backend();
    media_files::Entity::find()
        .filter(Expr::col(media_files::Column::MediaItemId).eq(wrapper.into_simple_expr(backend)))
        .filter(media_files::Column::EpisodeId.is_null())
        .filter(media_files::Column::TrashedAt.is_null())
        .order_by_asc(media_files::Column::InsertedAt)
        .one(db)
        .await
}

/// Fetch the first media file for an episode (analog of
/// `first_media_file_for_movie` but for episodes).
pub async fn first_media_file_for_episode(
    db: &DatabaseConnection,
    episode_id: &str,
) -> Result<Option<media_files::Model>, DbErr> {
    let Some(wrapper) = parse_uuid(episode_id) else {
        return Ok(None);
    };
    let backend = db.get_database_backend();
    media_files::Entity::find()
        .filter(Expr::col(media_files::Column::EpisodeId).eq(wrapper.into_simple_expr(backend)))
        .filter(media_files::Column::TrashedAt.is_null())
        .order_by_asc(media_files::Column::InsertedAt)
        .one(db)
        .await
}

/// List media files for a single episode.
#[allow(dead_code)]
pub async fn list_media_files_for_episode(
    db: &DatabaseConnection,
    episode_id: &str,
) -> Result<Vec<media_files::Model>, DbErr> {
    let Some(wrapper) = parse_uuid(episode_id) else {
        return Ok(Vec::new());
    };
    let backend = db.get_database_backend();
    media_files::Entity::find()
        .filter(Expr::col(media_files::Column::EpisodeId).eq(wrapper.into_simple_expr(backend)))
        .filter(media_files::Column::TrashedAt.is_null())
        .order_by_asc(media_files::Column::InsertedAt)
        .all(db)
        .await
}
