//! Port of the slice of `Mydia.Media` that the browse + discovery +
//! media resolvers consume. Each function targets a specific resolver
//! call site; expand as new resolvers come online in U10 / U11 / U14.
//!
//! sqlx-level conventions:
//!
//! - SQL is hand-written, not the `query!` macro, because the query
//!   shape depends on the dialect (column list is fixed but the
//!   parameter placeholder syntax `?` vs `$1` is rewritten by the
//!   sqlx driver layer).
//! - Column lists are explicit (`SELECT id, type, title, ...`) per
//!   the plan's `SELECT *` ban — additive Phoenix migrations stay
//!   tolerated.
//! - Each function returns `sqlx::Error`; resolvers translate to
//!   `async_graphql::Error` at the call site.

use mydia_rs_db::Db;
use mydia_rs_models::{Episode, MediaFile, MediaItem};
use sqlx::{Postgres, QueryBuilder, Sqlite};

const MEDIA_ITEM_COLUMNS: &str =
    "id, type, title, original_title, year, tmdb_id, tvdb_id, imdb_id, metadata, monitored, \
     monitoring_preset, category, category_override, seasons_refreshed_at, quality_profile_id, \
     inserted_at, updated_at";

const EPISODE_COLUMNS: &str =
    "id, media_item_id, season_number, episode_number, title, air_date, metadata, monitored, \
     inserted_at, updated_at";

const MEDIA_FILE_COLUMNS: &str =
    "id, media_item_id, episode_id, quality_profile_id, library_path_id, path, relative_path, \
     size, resolution, codec, hdr_format, audio_codec, bitrate, verified_at, analyzed_at, \
     analysis_attempts, last_analysis_error, metadata, cover_blob, sprite_blob, vtt_blob, \
     preview_blob, phash, generated_at, trashed_at, inserted_at, updated_at";

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

/// List media items, ordered by title ASC. Pagination and sort
/// happen in-memory in the resolver, mirroring Phoenix today (the
/// resolver `list_movies` fetches all, sorts, slices).
pub async fn list_media_items(
    db: &Db,
    opts: &ListMediaItemsOpts<'_>,
) -> Result<Vec<MediaItem>, sqlx::Error> {
    match db {
        Db::Sqlite(pool) => {
            let mut qb: QueryBuilder<Sqlite> = QueryBuilder::new("SELECT ");
            qb.push(MEDIA_ITEM_COLUMNS);
            qb.push(" FROM media_items WHERE 1=1");
            if let Some(kind) = opts.kind {
                qb.push(" AND type = ").push_bind(kind);
            }
            if let Some(category) = opts.category {
                qb.push(" AND category = ").push_bind(category);
            }
            if opts.has_files {
                qb.push(
                    " AND (\
                        id IN (SELECT DISTINCT media_item_id FROM media_files \
                                WHERE media_item_id IS NOT NULL) \
                        OR id IN (SELECT DISTINCT e.media_item_id FROM media_files mf \
                                  JOIN episodes e ON mf.episode_id = e.id))",
                );
            }
            if let Some(since) = opts.added_since {
                qb.push(" AND inserted_at >= ").push_bind(since);
            }
            if let Some(term) = opts.search {
                let pattern = format!("%{}%", term.to_lowercase());
                qb.push(" AND lower(title) LIKE ").push_bind(pattern);
            }
            qb.push(" ORDER BY title COLLATE NOCASE ASC");
            qb.build_query_as::<MediaItem>().fetch_all(pool).await
        }
        Db::Postgres(pool) => {
            let mut qb: QueryBuilder<Postgres> = QueryBuilder::new("SELECT ");
            qb.push(MEDIA_ITEM_COLUMNS);
            qb.push(" FROM media_items WHERE 1=1");
            if let Some(kind) = opts.kind {
                qb.push(" AND type = ").push_bind(kind);
            }
            if let Some(category) = opts.category {
                qb.push(" AND category = ").push_bind(category);
            }
            if opts.has_files {
                qb.push(
                    " AND (\
                        id IN (SELECT DISTINCT media_item_id FROM media_files \
                                WHERE media_item_id IS NOT NULL) \
                        OR id IN (SELECT DISTINCT e.media_item_id FROM media_files mf \
                                  JOIN episodes e ON mf.episode_id = e.id))",
                );
            }
            if let Some(since) = opts.added_since {
                qb.push(" AND inserted_at >= ").push_bind(since);
            }
            if let Some(term) = opts.search {
                let pattern = format!("%{}%", term.to_lowercase());
                qb.push(" AND lower(title) LIKE ").push_bind(pattern);
            }
            qb.push(" ORDER BY lower(title) ASC");
            qb.build_query_as::<MediaItem>().fetch_all(pool).await
        }
    }
}

/// Fetch one media item by UUID. Returns `Ok(None)` when the row
/// doesn't exist (resolvers translate to a GraphQL "not found"
/// error).
pub async fn get_media_item(db: &Db, id: &str) -> Result<Option<MediaItem>, sqlx::Error> {
    let sql = format!("SELECT {MEDIA_ITEM_COLUMNS} FROM media_items WHERE id = $1");
    match db {
        Db::Sqlite(pool) => {
            // SQLite uses `?` placeholders, but sqlx auto-rewrites
            // for query_as via the prepared API.
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, MediaItem>(&sql)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, MediaItem>(&sql)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
    }
}

/// Fetch one episode by UUID.
pub async fn get_episode(db: &Db, id: &str) -> Result<Option<Episode>, sqlx::Error> {
    let sql = format!("SELECT {EPISODE_COLUMNS} FROM episodes WHERE id = $1");
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, Episode>(&sql)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, Episode>(&sql)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
    }
}

/// List episodes for a given media item, ordered by season then
/// episode number.
pub async fn list_episodes(db: &Db, media_item_id: &str) -> Result<Vec<Episode>, sqlx::Error> {
    let sql = format!(
        "SELECT {EPISODE_COLUMNS} FROM episodes WHERE media_item_id = $1 \
         ORDER BY season_number ASC, episode_number ASC"
    );
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, Episode>(&sql)
                .bind(media_item_id)
                .fetch_all(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, Episode>(&sql)
                .bind(media_item_id)
                .fetch_all(pool)
                .await
        }
    }
}

/// Whether at least one media file exists for the given episode.
/// Used by `get_season` to determine the `has_files` flag.
pub async fn episode_has_files(db: &Db, episode_id: &str) -> Result<bool, sqlx::Error> {
    let sql = "SELECT EXISTS(SELECT 1 FROM media_files WHERE episode_id = $1)";
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            let exists: bool = sqlx::query_scalar(&sql)
                .bind(episode_id)
                .fetch_one(pool)
                .await?;
            Ok(exists)
        }
        Db::Postgres(pool) => {
            let exists: bool = sqlx::query_scalar(sql)
                .bind(episode_id)
                .fetch_one(pool)
                .await?;
            Ok(exists)
        }
    }
}

/// List media files for a media item (movies — episode-less files).
#[allow(dead_code)]
pub async fn list_media_files_for_movie(
    db: &Db,
    media_item_id: &str,
) -> Result<Vec<MediaFile>, sqlx::Error> {
    let sql = format!(
        "SELECT {MEDIA_FILE_COLUMNS} FROM media_files \
         WHERE media_item_id = $1 AND episode_id IS NULL AND trashed_at IS NULL \
         ORDER BY inserted_at ASC"
    );
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, MediaFile>(&sql)
                .bind(media_item_id)
                .fetch_all(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, MediaFile>(&sql)
                .bind(media_item_id)
                .fetch_all(pool)
                .await
        }
    }
}

/// Fetch a single media file by ID. Used by the streaming resolvers
/// to resolve `file_id` arguments to a `MediaFile` row before
/// computing candidates or starting a session.
pub async fn get_media_file(db: &Db, id: &str) -> Result<Option<MediaFile>, sqlx::Error> {
    let sql = format!("SELECT {MEDIA_FILE_COLUMNS} FROM media_files WHERE id = $1");
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, MediaFile>(&sql)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, MediaFile>(&sql)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
    }
}

/// Fetch the first media file associated with a media item (used for
/// `streamingCandidates(contentType: "movie", id: ...)` lookup).
pub async fn first_media_file_for_movie(
    db: &Db,
    media_item_id: &str,
) -> Result<Option<MediaFile>, sqlx::Error> {
    let sql = format!(
        "SELECT {MEDIA_FILE_COLUMNS} FROM media_files \
         WHERE media_item_id = $1 AND episode_id IS NULL AND trashed_at IS NULL \
         ORDER BY inserted_at ASC LIMIT 1"
    );
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, MediaFile>(&sql)
                .bind(media_item_id)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, MediaFile>(&sql)
                .bind(media_item_id)
                .fetch_optional(pool)
                .await
        }
    }
}

/// Fetch the first media file for an episode (analog of
/// `first_media_file_for_movie` but for episodes).
pub async fn first_media_file_for_episode(
    db: &Db,
    episode_id: &str,
) -> Result<Option<MediaFile>, sqlx::Error> {
    let sql = format!(
        "SELECT {MEDIA_FILE_COLUMNS} FROM media_files \
         WHERE episode_id = $1 AND trashed_at IS NULL \
         ORDER BY inserted_at ASC LIMIT 1"
    );
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, MediaFile>(&sql)
                .bind(episode_id)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, MediaFile>(&sql)
                .bind(episode_id)
                .fetch_optional(pool)
                .await
        }
    }
}

/// List media files for a single episode.
#[allow(dead_code)]
pub async fn list_media_files_for_episode(
    db: &Db,
    episode_id: &str,
) -> Result<Vec<MediaFile>, sqlx::Error> {
    let sql = format!(
        "SELECT {MEDIA_FILE_COLUMNS} FROM media_files \
         WHERE episode_id = $1 AND trashed_at IS NULL \
         ORDER BY inserted_at ASC"
    );
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, MediaFile>(&sql)
                .bind(episode_id)
                .fetch_all(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, MediaFile>(&sql)
                .bind(episode_id)
                .fetch_all(pool)
                .await
        }
    }
}
