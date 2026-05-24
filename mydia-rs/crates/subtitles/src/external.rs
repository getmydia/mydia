//! External subtitle file listing.
//!
//! Port of `Mydia.Subtitles.list_subtitles/1` (`lib/mydia/subtitles.ex`).
//! Queries the `subtitles` table for a media file's operator-uploaded
//! or provider-downloaded sidecars. The REST index handler stitches
//! these together with `extractor::list_embedded_tracks` so the player
//! sees both sets in one response.
//!
//! Post-U7 cutover: SeaORM-native. The UUID wrapper handles the
//! TEXT-vs-`uuid` divergence at the bind/read layer, and the
//! `ORDER BY rating DESC NULLS LAST, language ASC` is engine-portable
//! through SeaORM's `order_by_with_nulls` builder (SQLite ≥3.30 and
//! Postgres both support NULLS LAST).

use sea_orm::entity::prelude::*;
use sea_orm::query::{Order, QueryOrder, QuerySelect};
use sea_orm::sea_query::{Expr, ExprTrait, NullOrdering};
use sea_orm::{DatabaseConnection, DbErr, FromQueryResult};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use mydia_rs_db::types::UuidText;
use mydia_rs_entities::subtitles;

/// Track descriptor for an external subtitle file, scoped to the
/// fields the player needs. Mirrors the index endpoint's wire shape
/// for embedded tracks one-for-one so the handler can merge the two
/// lists without a separate JSON-shape branch.
#[derive(Debug, Clone, Serialize, Deserialize, FromQueryResult)]
pub struct ExternalTrack {
    /// `subtitles.id` UUID — the value the player echoes back on the
    /// extraction endpoint to identify the row.
    pub track_id: UuidText,
    /// `subtitles.language` (ISO 639 code or fuller string).
    pub language: String,
    /// `subtitles.format` (`srt` / `ass` / `vtt`).
    pub format: String,
    /// `subtitles.file_path` — absolute path on disk. Held on the
    /// struct so the handler can serve the file without re-querying
    /// when the player drills into a specific track.
    pub file_path: String,
}

/// Parse a `&str` media_file_id to the `UuidText` wrapper so the same
/// bind value works on both SQLite (encodes as TEXT) and Postgres
/// (encodes as native `uuid`). Invalid input maps to None — callers
/// treat that as "no rows match" without raising a DB error.
fn parse_uuid(s: &str) -> Option<UuidText> {
    Uuid::parse_str(s).ok().map(UuidText::from)
}

/// List external subtitles for a media file id, ordered the same way
/// Phoenix does (`desc: rating, asc: language`). Returns an empty Vec
/// when nothing matches.
pub async fn list_external_tracks(
    db: &DatabaseConnection,
    media_file_id: &str,
) -> Result<Vec<ExternalTrack>, DbErr> {
    let Some(mfid) = parse_uuid(media_file_id) else {
        return Ok(Vec::new());
    };
    let backend = db.get_database_backend();

    subtitles::Entity::find()
        .select_only()
        .column_as(subtitles::Column::Id, "track_id")
        .column(subtitles::Column::Language)
        .column(subtitles::Column::Format)
        .column(subtitles::Column::FilePath)
        .filter(Expr::col(subtitles::Column::MediaFileId).eq(mfid.into_simple_expr(backend)))
        .order_by_with_nulls(subtitles::Column::Rating, Order::Desc, NullOrdering::Last)
        .order_by_asc(subtitles::Column::Language)
        .into_model::<ExternalTrack>()
        .all(db)
        .await
}

/// Fetch a single external subtitle by id, but only when it belongs
/// to the given media file. Mirrors Phoenix's
/// `extract_subtitle_track/3` for the binary-id branch: rejecting
/// cross-media-file lookups is defense-in-depth because the REST
/// handler already scoped the row by URL.
pub async fn get_external_track_for_media_file(
    db: &DatabaseConnection,
    subtitle_id: &str,
    media_file_id: &str,
) -> Result<Option<ExternalTrack>, DbErr> {
    let Some(sid) = parse_uuid(subtitle_id) else {
        return Ok(None);
    };
    let Some(mfid) = parse_uuid(media_file_id) else {
        return Ok(None);
    };
    let backend = db.get_database_backend();

    subtitles::Entity::find()
        .select_only()
        .column_as(subtitles::Column::Id, "track_id")
        .column(subtitles::Column::Language)
        .column(subtitles::Column::Format)
        .column(subtitles::Column::FilePath)
        .filter(Expr::col(subtitles::Column::Id).eq(sid.into_simple_expr(backend)))
        .filter(Expr::col(subtitles::Column::MediaFileId).eq(mfid.into_simple_expr(backend)))
        .limit(1)
        .into_model::<ExternalTrack>()
        .one(db)
        .await
}
