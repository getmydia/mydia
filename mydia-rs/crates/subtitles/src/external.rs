//! External subtitle file listing.
//!
//! Port of `Mydia.Subtitles.list_subtitles/1` (`lib/mydia/subtitles.ex`).
//! Queries the `subtitles` table for a media file's operator-uploaded
//! or provider-downloaded sidecars. The REST index handler stitches
//! these together with `extractor::list_embedded_tracks` so the player
//! sees both sets in one response.
//!
//! The Rust port lives in this crate (rather than `db` or `models`)
//! because the only consumer today is the subtitle REST handler.
//! Other call sites can pull the [`mydia_rs_models::Subtitle`] row
//! directly via sqlx without going through this helper.

use serde::{Deserialize, Serialize};

use mydia_rs_db::Db;

/// Track descriptor for an external subtitle file, scoped to the
/// fields the player needs. Mirrors the index endpoint's wire shape
/// for embedded tracks one-for-one so the handler can merge the two
/// lists without a separate JSON-shape branch.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct ExternalTrack {
    /// `subtitles.id` UUID — the value the player echoes back on the
    /// extraction endpoint to identify the row.
    #[sqlx(rename = "id")]
    pub track_id: String,
    /// `subtitles.language` (ISO 639 code or fuller string).
    pub language: String,
    /// `subtitles.format` (`srt` / `ass` / `vtt`).
    pub format: String,
    /// `subtitles.file_path` — absolute path on disk. Held on the
    /// struct so the handler can serve the file without re-querying
    /// when the player drills into a specific track.
    pub file_path: String,
}

/// List external subtitles for a media file id, ordered the same way
/// Phoenix does (`desc: rating, asc: language`). Returns an empty Vec
/// when nothing matches.
pub async fn list_external_tracks(
    db: &Db,
    media_file_id: &str,
) -> Result<Vec<ExternalTrack>, sqlx::Error> {
    match db {
        Db::Sqlite(pool) => {
            sqlx::query_as::<_, ExternalTrack>(
                "SELECT id, language, format, file_path \
                 FROM subtitles \
                 WHERE media_file_id = ? \
                 ORDER BY rating DESC, language ASC",
            )
            .bind(media_file_id)
            .fetch_all(pool)
            .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, ExternalTrack>(
                "SELECT id::text AS id, language, format, file_path \
                 FROM subtitles \
                 WHERE media_file_id::text = $1 \
                 ORDER BY rating DESC NULLS LAST, language ASC",
            )
            .bind(media_file_id)
            .fetch_all(pool)
            .await
        }
    }
}

/// Fetch a single external subtitle by id, but only when it belongs
/// to the given media file. Mirrors Phoenix's
/// `extract_subtitle_track/3` for the binary-id branch: rejecting
/// cross-media-file lookups is defense-in-depth because the REST
/// handler already scoped the row by URL.
pub async fn get_external_track_for_media_file(
    db: &Db,
    subtitle_id: &str,
    media_file_id: &str,
) -> Result<Option<ExternalTrack>, sqlx::Error> {
    match db {
        Db::Sqlite(pool) => {
            sqlx::query_as::<_, ExternalTrack>(
                "SELECT id, language, format, file_path \
                 FROM subtitles \
                 WHERE id = ? AND media_file_id = ? \
                 LIMIT 1",
            )
            .bind(subtitle_id)
            .bind(media_file_id)
            .fetch_optional(pool)
            .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, ExternalTrack>(
                "SELECT id::text AS id, language, format, file_path \
                 FROM subtitles \
                 WHERE id::text = $1 AND media_file_id::text = $2 \
                 LIMIT 1",
            )
            .bind(subtitle_id)
            .bind(media_file_id)
            .fetch_optional(pool)
            .await
        }
    }
}
