// Opt this module into the disallowed-methods lint so a future patch
// that backslides into runtime `sqlx::query`/`query_as` (instead of the
// compile-time-checked macros) is flagged at clippy time. The workspace
// baseline keeps the lint at `allow` so unconverted call sites don't
// block CI; converted modules opt in here.
#![warn(clippy::disallowed_methods)]

//! External subtitle file listing.
//!
//! Port of `Mydia.Subtitles.list_subtitles/1` (`lib/mydia/subtitles.ex`).
//! Queries the `subtitles` table for a media file's operator-uploaded
//! or provider-downloaded sidecars. The REST index handler stitches
//! these together with `extractor::list_embedded_tracks` so the player
//! sees both sets in one response.
//!
//! Tier-(a) portable SQL: both engines run byte-equal queries. The
//! UUID encoding divergence (TEXT on SQLite, native `uuid` on Postgres)
//! is bridged at the type-wrapper layer ([`UuidText`]), not in SQL.
//! `NULLS LAST` is supported on SQLite ≥3.30 (Phoenix's ecto_sqlite3
//! pulls in 3.46+), so the ORDER BY is engine-portable.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use mydia_rs_db::types::UuidText;
use mydia_rs_db::Db;

/// Track descriptor for an external subtitle file, scoped to the
/// fields the player needs. Mirrors the index endpoint's wire shape
/// for embedded tracks one-for-one so the handler can merge the two
/// lists without a separate JSON-shape branch.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
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
    db: &Db,
    media_file_id: &str,
) -> Result<Vec<ExternalTrack>, sqlx::Error> {
    let Some(mfid) = parse_uuid(media_file_id) else {
        return Ok(Vec::new());
    };

    match db {
        Db::Sqlite(pool) => {
            // SQLite arm uses the runtime form because `sqlx::query_as!`
            // is single-dialect at compile time and our prepare target
            // is Postgres. The SQL is byte-equal to the macro-checked
            // Postgres arm; portability is enforced by the matching
            // test fixture and CI's dual-engine integration matrix.
            #[allow(clippy::disallowed_methods)]
            sqlx::query_as::<_, ExternalTrack>(
                "SELECT id AS track_id, language, format, file_path \
                 FROM subtitles \
                 WHERE media_file_id = $1 \
                 ORDER BY rating DESC NULLS LAST, language ASC",
            )
            .bind(mfid)
            .fetch_all(pool)
            .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as!(
                ExternalTrack,
                r#"SELECT
                    id AS "track_id!: UuidText",
                    language as "language!",
                    format as "format!",
                    file_path as "file_path!"
                  FROM subtitles
                  WHERE media_file_id = $1
                  ORDER BY rating DESC NULLS LAST, language ASC"#,
                mfid as UuidText
            )
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
    let Some(sid) = parse_uuid(subtitle_id) else {
        return Ok(None);
    };
    let Some(mfid) = parse_uuid(media_file_id) else {
        return Ok(None);
    };

    match db {
        Db::Sqlite(pool) =>
        {
            #[allow(clippy::disallowed_methods)]
            sqlx::query_as::<_, ExternalTrack>(
                "SELECT id AS track_id, language, format, file_path \
                 FROM subtitles \
                 WHERE id = $1 AND media_file_id = $2 \
                 LIMIT 1",
            )
            .bind(sid)
            .bind(mfid)
            .fetch_optional(pool)
            .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as!(
                ExternalTrack,
                r#"SELECT
                    id AS "track_id!: UuidText",
                    language as "language!",
                    format as "format!",
                    file_path as "file_path!"
                  FROM subtitles
                  WHERE id = $1 AND media_file_id = $2
                  LIMIT 1"#,
                sid as UuidText,
                mfid as UuidText
            )
            .fetch_optional(pool)
            .await
        }
    }
}
