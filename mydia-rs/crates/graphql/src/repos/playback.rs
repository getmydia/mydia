//! Port of the `Mydia.Playback` context slice the playback mutations
//! consume.
//!
//! The Phoenix module at `lib/mydia/playback.ex` wraps the
//! `playback_progress` Ecto schema's upsert / get / delete operations.
//! Mirrored here with sqlx, with the schema validations the
//! changeset enforces translated into Rust checks at the call site.
//!
//! `completion_percentage` is derived from position/duration during the
//! write (Phoenix does this inside the changeset; we mirror to keep
//! the on-disk shape identical across backends). The `watched` flag is
//! auto-true at >= 90% completion.

use chrono::{DateTime, Utc};
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_db::Db;
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use uuid::Uuid;

/// Foreign-key form. A progress row is either tied to a media item
/// (movie) or to an episode — never both. Mirrors Phoenix's
/// `validate_one_parent` changeset check.
#[derive(Debug, Clone, Copy)]
pub enum Parent<'a> {
    MediaItem(&'a str),
    Episode(&'a str),
}

impl<'a> Parent<'a> {
    pub fn as_movie_id(self) -> Option<&'a str> {
        if let Self::MediaItem(id) = self {
            Some(id)
        } else {
            None
        }
    }

    pub fn as_episode_id(self) -> Option<&'a str> {
        if let Self::Episode(id) = self {
            Some(id)
        } else {
            None
        }
    }
}

/// On-disk row shape. Field set mirrors
/// `Mydia.Playback.Progress` at `lib/mydia/playback/progress.ex:11`.
#[derive(Debug, Clone, FromRow, Serialize, Deserialize)]
pub struct ProgressRow {
    pub id: UuidText,
    pub user_id: UuidText,
    pub media_item_id: Option<UuidText>,
    pub episode_id: Option<UuidText>,
    pub position_seconds: i32,
    pub duration_seconds: i32,
    pub completion_percentage: f64,
    pub watched: bool,
    pub last_watched_at: DateTimeSecs,
    pub inserted_at: DateTimeSecs,
    pub updated_at: DateTimeSecs,
}

/// Input bundle for a progress write. Optional fields default to
/// preserving the existing row (insert: 0, update: existing value).
#[derive(Debug, Clone, Default)]
pub struct ProgressUpsert {
    pub position_seconds: Option<i32>,
    pub duration_seconds: Option<i32>,
    /// When provided, overrides the auto-derived `last_watched_at`.
    pub last_watched_at: Option<DateTime<Utc>>,
    /// When `Some(true)`, forces the row's `watched` flag on (used by
    /// `mark_watched`). The default leaves the auto-mark logic to
    /// derive from completion percentage.
    pub watched_override: Option<bool>,
}

/// Validation error from the upsert path. Caller (the resolver)
/// translates these into `async_graphql::Error`s with the same
/// shape Phoenix surfaces from `format_changeset_errors`.
#[derive(Debug, thiserror::Error)]
pub enum ProgressError {
    #[error("position_seconds: must be greater than or equal to 0")]
    NegativePosition,
    #[error("duration_seconds: must be greater than 0")]
    NonPositiveDuration,
    #[error("position_seconds: is required")]
    MissingPosition,
    #[error("duration_seconds: is required")]
    MissingDuration,
    #[error(transparent)]
    Db(#[from] sqlx::Error),
}

/// Fetch the single progress row for (user, parent) or `None`.
pub async fn get_progress(
    db: &Db,
    user_id: &str,
    parent: Parent<'_>,
) -> Result<Option<ProgressRow>, sqlx::Error> {
    let (column, value) = match parent {
        Parent::MediaItem(id) => ("media_item_id", id),
        Parent::Episode(id) => ("episode_id", id),
    };
    let sql = format!(
        "SELECT id, user_id, media_item_id, episode_id, position_seconds, \
         duration_seconds, completion_percentage, watched, last_watched_at, \
         inserted_at, updated_at \
         FROM playback_progress \
         WHERE user_id = $1 AND {column} = $2"
    );
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?").replace("$2", "?");
            sqlx::query_as::<_, ProgressRow>(&sql)
                .bind(user_id)
                .bind(value)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, ProgressRow>(&sql)
                .bind(user_id)
                .bind(value)
                .fetch_optional(pool)
                .await
        }
    }
}

/// Upsert progress for (user, parent). When no row exists this inserts
/// one with the supplied position/duration; otherwise it updates the
/// fields the caller specified. Returns the resulting row.
pub async fn upsert_progress(
    db: &Db,
    user_id: &str,
    parent: Parent<'_>,
    update: ProgressUpsert,
) -> Result<ProgressRow, ProgressError> {
    if let Some(pos) = update.position_seconds {
        if pos < 0 {
            return Err(ProgressError::NegativePosition);
        }
    }
    if let Some(dur) = update.duration_seconds {
        if dur <= 0 {
            return Err(ProgressError::NonPositiveDuration);
        }
    }

    let existing = get_progress(db, user_id, parent).await?;
    let now = Utc::now();
    let last_watched_at = update.last_watched_at.unwrap_or(now);

    match existing {
        Some(row) => {
            let pos = update.position_seconds.unwrap_or(row.position_seconds);
            let dur = update.duration_seconds.unwrap_or(row.duration_seconds);
            if dur <= 0 {
                return Err(ProgressError::NonPositiveDuration);
            }
            let percentage = (pos as f64) / (dur as f64) * 100.0;
            let watched = update
                .watched_override
                .unwrap_or(row.watched || percentage >= 90.0);

            let row_id = row.id.0.to_string();
            let last_watched = DateTimeSecs::from(last_watched_at);
            let updated_at = DateTimeSecs::from(now);

            match db {
                Db::Sqlite(pool) => {
                    sqlx::query(
                        "UPDATE playback_progress SET \
                            position_seconds = ?, duration_seconds = ?, \
                            completion_percentage = ?, watched = ?, \
                            last_watched_at = ?, updated_at = ? \
                         WHERE id = ?",
                    )
                    .bind(pos)
                    .bind(dur)
                    .bind(percentage)
                    .bind(watched)
                    .bind(last_watched)
                    .bind(updated_at)
                    .bind(&row_id)
                    .execute(pool)
                    .await?;
                }
                Db::Postgres(pool) => {
                    sqlx::query(
                        "UPDATE playback_progress SET \
                            position_seconds = $1, duration_seconds = $2, \
                            completion_percentage = $3, watched = $4, \
                            last_watched_at = $5, updated_at = $6 \
                         WHERE id = $7",
                    )
                    .bind(pos)
                    .bind(dur)
                    .bind(percentage)
                    .bind(watched)
                    .bind(last_watched)
                    .bind(updated_at)
                    .bind(&row_id)
                    .execute(pool)
                    .await?;
                }
            }

            get_progress(db, user_id, parent)
                .await?
                .ok_or(ProgressError::Db(sqlx::Error::RowNotFound))
        }
        None => {
            let pos = update
                .position_seconds
                .ok_or(ProgressError::MissingPosition)?;
            let dur = update
                .duration_seconds
                .ok_or(ProgressError::MissingDuration)?;
            let percentage = (pos as f64) / (dur as f64) * 100.0;
            let watched = update.watched_override.unwrap_or(percentage >= 90.0);
            let id = UuidText::new_v4();
            let movie_id = parent
                .as_movie_id()
                .map(|s| Uuid::parse_str(s).map(UuidText::from))
                .transpose()
                .map_err(|_| ProgressError::Db(sqlx::Error::RowNotFound))?;
            let episode_id = parent
                .as_episode_id()
                .map(|s| Uuid::parse_str(s).map(UuidText::from))
                .transpose()
                .map_err(|_| ProgressError::Db(sqlx::Error::RowNotFound))?;
            let user_uuid = Uuid::parse_str(user_id)
                .map(UuidText::from)
                .map_err(|_| ProgressError::Db(sqlx::Error::RowNotFound))?;
            let last_watched = DateTimeSecs::from(last_watched_at);
            let timestamps = DateTimeSecs::from(now);

            match db {
                Db::Sqlite(pool) => {
                    sqlx::query(
                        "INSERT INTO playback_progress \
                         (id, user_id, media_item_id, episode_id, position_seconds, \
                          duration_seconds, completion_percentage, watched, \
                          last_watched_at, inserted_at, updated_at) \
                         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    )
                    .bind(id)
                    .bind(user_uuid)
                    .bind(movie_id)
                    .bind(episode_id)
                    .bind(pos)
                    .bind(dur)
                    .bind(percentage)
                    .bind(watched)
                    .bind(last_watched)
                    .bind(timestamps)
                    .bind(timestamps)
                    .execute(pool)
                    .await?;
                }
                Db::Postgres(pool) => {
                    sqlx::query(
                        "INSERT INTO playback_progress \
                         (id, user_id, media_item_id, episode_id, position_seconds, \
                          duration_seconds, completion_percentage, watched, \
                          last_watched_at, inserted_at, updated_at) \
                         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)",
                    )
                    .bind(id)
                    .bind(user_uuid)
                    .bind(movie_id)
                    .bind(episode_id)
                    .bind(pos)
                    .bind(dur)
                    .bind(percentage)
                    .bind(watched)
                    .bind(last_watched)
                    .bind(timestamps)
                    .bind(timestamps)
                    .execute(pool)
                    .await?;
                }
            }

            get_progress(db, user_id, parent)
                .await?
                .ok_or(ProgressError::Db(sqlx::Error::RowNotFound))
        }
    }
}

/// Set `watched = true` on the existing row, if any. Mirrors
/// `Mydia.Playback.mark_watched/2`. Returns `Ok(None)` when no row
/// exists (resolvers fall back to creating one).
pub async fn mark_watched(
    db: &Db,
    user_id: &str,
    parent: Parent<'_>,
) -> Result<Option<ProgressRow>, sqlx::Error> {
    let existing = get_progress(db, user_id, parent).await?;
    let Some(row) = existing else {
        return Ok(None);
    };
    let row_id = row.id.0.to_string();
    let updated_at = DateTimeSecs::from(Utc::now());
    match db {
        Db::Sqlite(pool) => {
            sqlx::query("UPDATE playback_progress SET watched = 1, updated_at = ? WHERE id = ?")
                .bind(updated_at)
                .bind(&row_id)
                .execute(pool)
                .await?;
        }
        Db::Postgres(pool) => {
            sqlx::query(
                "UPDATE playback_progress SET watched = TRUE, updated_at = $1 WHERE id = $2",
            )
            .bind(updated_at)
            .bind(&row_id)
            .execute(pool)
            .await?;
        }
    }
    get_progress(db, user_id, parent).await
}

/// Delete the progress row, if any. Mirrors
/// `Mydia.Playback.delete_progress/2`.
pub async fn delete_progress(
    db: &Db,
    user_id: &str,
    parent: Parent<'_>,
) -> Result<bool, sqlx::Error> {
    let existing = get_progress(db, user_id, parent).await?;
    let Some(row) = existing else {
        return Ok(false);
    };
    let row_id = row.id.0.to_string();
    match db {
        Db::Sqlite(pool) => {
            sqlx::query("DELETE FROM playback_progress WHERE id = ?")
                .bind(&row_id)
                .execute(pool)
                .await?;
        }
        Db::Postgres(pool) => {
            sqlx::query("DELETE FROM playback_progress WHERE id = $1")
                .bind(&row_id)
                .execute(pool)
                .await?;
        }
    }
    Ok(true)
}
