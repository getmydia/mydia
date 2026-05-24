//! Port of the `Mydia.Playback` context slice the playback mutations
//! consume.
//!
//! The Phoenix module at `lib/mydia/playback.ex` wraps the
//! `playback_progress` Ecto schema's upsert / get / delete operations.
//! Mirrored here with `SeaORM`, with the schema validations the
//! changeset enforces translated into Rust checks at the call site.
//!
//! `completion_percentage` is derived from position/duration during the
//! write (Phoenix does this inside the changeset; we mirror to keep
//! the on-disk shape identical across backends). The `watched` flag is
//! auto-true at >= 90% completion.
//!
//! Post-U13 cutover: SeaORM-native. Inserts use
//! `mydia_rs_db::insert_active_model`; targeted UPDATEs use
//! `Entity::update_many().col_expr(...)` with wrapper bind values.

use chrono::{DateTime, Utc};
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_entities::playback_progress;
use sea_orm::entity::prelude::*;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{DatabaseConnection, Set};
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

/// On-disk row shape — re-export of the entity's `Model`. Resolvers
/// consume this type by field; the existing field names match
/// Phoenix's column names so no remapping is needed.
pub type ProgressRow = playback_progress::Model;

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
    Db(#[from] DbErr),
}

/// Fetch the single progress row for (user, parent) or `None`.
pub async fn get_progress(
    db: &DatabaseConnection,
    user_id: &str,
    parent: Parent<'_>,
) -> Result<Option<ProgressRow>, DbErr> {
    let Ok(user_uuid) = Uuid::parse_str(user_id) else {
        return Ok(None);
    };
    let user_wrapper = UuidText::from(user_uuid);
    let backend = db.get_database_backend();
    let mut q = playback_progress::Entity::find().filter(
        Expr::col(playback_progress::Column::UserId).eq(user_wrapper.into_simple_expr(backend)),
    );
    match parent {
        Parent::MediaItem(id) => {
            let Ok(uuid) = Uuid::parse_str(id) else {
                return Ok(None);
            };
            let wrapper = UuidText::from(uuid);
            q = q.filter(
                Expr::col(playback_progress::Column::MediaItemId)
                    .eq(wrapper.into_simple_expr(backend)),
            );
        }
        Parent::Episode(id) => {
            let Ok(uuid) = Uuid::parse_str(id) else {
                return Ok(None);
            };
            let wrapper = UuidText::from(uuid);
            q = q.filter(
                Expr::col(playback_progress::Column::EpisodeId)
                    .eq(wrapper.into_simple_expr(backend)),
            );
        }
    }
    q.one(db).await
}

/// Upsert progress for (user, parent). When no row exists this inserts
/// one with the supplied position/duration; otherwise it updates the
/// fields the caller specified. Returns the resulting row.
pub async fn upsert_progress(
    db: &DatabaseConnection,
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
    let backend = db.get_database_backend();

    if let Some(row) = existing {
        let pos = update.position_seconds.unwrap_or(row.position_seconds);
        let dur = update.duration_seconds.unwrap_or(row.duration_seconds);
        if dur <= 0 {
            return Err(ProgressError::NonPositiveDuration);
        }
        let percentage = f64::from(pos) / f64::from(dur) * 100.0;
        let watched = update
            .watched_override
            .unwrap_or(row.watched || percentage >= 90.0);

        let last_watched = DateTimeSecs::from(last_watched_at);
        let updated_at = DateTimeSecs::from(now);

        playback_progress::Entity::update_many()
            .col_expr(
                playback_progress::Column::PositionSeconds,
                Expr::value(pos),
            )
            .col_expr(
                playback_progress::Column::DurationSeconds,
                Expr::value(dur),
            )
            .col_expr(
                playback_progress::Column::CompletionPercentage,
                Expr::value(percentage),
            )
            .col_expr(playback_progress::Column::Watched, Expr::value(watched))
            .col_expr(
                playback_progress::Column::LastWatchedAt,
                last_watched.into_simple_expr(backend),
            )
            .col_expr(
                playback_progress::Column::UpdatedAt,
                updated_at.into_simple_expr(backend),
            )
            .filter(
                Expr::col(playback_progress::Column::Id).eq(row.id.into_simple_expr(backend)),
            )
            .exec(db)
            .await
            .map_err(ProgressError::Db)?;

        get_progress(db, user_id, parent)
            .await?
            .ok_or(ProgressError::Db(DbErr::RecordNotFound(
                "playback_progress".to_owned(),
            )))
    } else {
        let pos = update
            .position_seconds
            .ok_or(ProgressError::MissingPosition)?;
        let dur = update
            .duration_seconds
            .ok_or(ProgressError::MissingDuration)?;
        let percentage = f64::from(pos) / f64::from(dur) * 100.0;
        let watched = update.watched_override.unwrap_or(percentage >= 90.0);
        let id = UuidText::new_v4();
        let movie_id = parent
            .as_movie_id()
            .map(|s| Uuid::parse_str(s).map(UuidText::from))
            .transpose()
            .map_err(|err| ProgressError::Db(DbErr::Custom(err.to_string())))?;
        let episode_id = parent
            .as_episode_id()
            .map(|s| Uuid::parse_str(s).map(UuidText::from))
            .transpose()
            .map_err(|err| ProgressError::Db(DbErr::Custom(err.to_string())))?;
        let user_uuid = Uuid::parse_str(user_id)
            .map(UuidText::from)
            .map_err(|err| ProgressError::Db(DbErr::Custom(err.to_string())))?;
        let last_watched = DateTimeSecs::from(last_watched_at);
        let timestamps = DateTimeSecs::from(now);

        let am = playback_progress::ActiveModel {
            id: Set(id),
            user_id: Set(user_uuid),
            media_item_id: Set(movie_id),
            episode_id: Set(episode_id),
            position_seconds: Set(pos),
            duration_seconds: Set(dur),
            completion_percentage: Set(percentage),
            watched: Set(watched),
            last_watched_at: Set(last_watched),
            inserted_at: Set(timestamps),
            updated_at: Set(timestamps),
        };
        let row = mydia_rs_db::insert_active_model(am, db)
            .await
            .map_err(ProgressError::Db)?;
        Ok(row)
    }
}

/// Set `watched = true` on the existing row, if any. Mirrors
/// `Mydia.Playback.mark_watched/2`. Returns `Ok(None)` when no row
/// exists (resolvers fall back to creating one).
pub async fn mark_watched(
    db: &DatabaseConnection,
    user_id: &str,
    parent: Parent<'_>,
) -> Result<Option<ProgressRow>, DbErr> {
    let existing = get_progress(db, user_id, parent).await?;
    let Some(row) = existing else {
        return Ok(None);
    };
    let backend = db.get_database_backend();
    let updated_at = DateTimeSecs::from(Utc::now());
    playback_progress::Entity::update_many()
        .col_expr(playback_progress::Column::Watched, Expr::value(true))
        .col_expr(
            playback_progress::Column::UpdatedAt,
            updated_at.into_simple_expr(backend),
        )
        .filter(Expr::col(playback_progress::Column::Id).eq(row.id.into_simple_expr(backend)))
        .exec(db)
        .await?;
    get_progress(db, user_id, parent).await
}

/// Delete the progress row, if any. Mirrors
/// `Mydia.Playback.delete_progress/2`.
pub async fn delete_progress(
    db: &DatabaseConnection,
    user_id: &str,
    parent: Parent<'_>,
) -> Result<bool, DbErr> {
    let existing = get_progress(db, user_id, parent).await?;
    let Some(row) = existing else {
        return Ok(false);
    };
    let backend = db.get_database_backend();
    playback_progress::Entity::delete_many()
        .filter(Expr::col(playback_progress::Column::Id).eq(row.id.into_simple_expr(backend)))
        .exec(db)
        .await?;
    Ok(true)
}

