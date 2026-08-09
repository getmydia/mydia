use chrono::Utc;

use crate::{Db, DbError};

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct ExternalSubtitleRow {
    pub id: String,
    pub media_file_id: String,
    pub path: String,
    pub language: String,
    pub format: String,
    pub discovered_at: String,
}

#[derive(Debug, Clone)]
pub struct NewExternalSubtitle {
    pub media_file_id: String,
    pub path: String,
    pub language: String,
    pub format: String,
}

const SELECT: &str = "SELECT id, media_file_id, path, language, format, discovered_at
                      FROM external_subtitles";

/// Keyed on path, so a rescan refreshes the row rather than adding a second
/// one. The id is stable across rescans, which matters because it is the
/// `trackId` the player asks for later.
pub async fn upsert(db: &Db, new: NewExternalSubtitle) -> Result<ExternalSubtitleRow, DbError> {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();

    let row = sqlx::query_as::<_, ExternalSubtitleRow>(
        "INSERT INTO external_subtitles (id, media_file_id, path, language, format, discovered_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(path) DO UPDATE SET
             media_file_id = excluded.media_file_id,
             language = excluded.language,
             format = excluded.format
         RETURNING id, media_file_id, path, language, format, discovered_at",
    )
    .bind(&id)
    .bind(&new.media_file_id)
    .bind(&new.path)
    .bind(&new.language)
    .bind(&new.format)
    .bind(&now)
    .fetch_one(db.pool())
    .await?;

    Ok(row)
}

pub async fn list_for_file(
    db: &Db,
    media_file_id: &str,
) -> Result<Vec<ExternalSubtitleRow>, DbError> {
    let rows = sqlx::query_as::<_, ExternalSubtitleRow>(&format!(
        "{SELECT} WHERE media_file_id = ?1 ORDER BY language, path"
    ))
    .bind(media_file_id)
    .fetch_all(db.pool())
    .await?;

    Ok(rows)
}

/// Loads external subtitles for many files at once.
///
/// A show detail query holds every file of every episode, so asking per file
/// turns one request into one query per episode. Chunked because SQLite caps
/// bound parameters per statement, and a large enough library would otherwise
/// fail on the limit rather than merely being slow.
pub async fn list_for_files(
    db: &Db,
    media_file_ids: &[String],
) -> Result<Vec<ExternalSubtitleRow>, DbError> {
    const CHUNK: usize = 500;

    let mut out = Vec::new();

    for chunk in media_file_ids.chunks(CHUNK) {
        let placeholders = (1..=chunk.len())
            .map(|i| format!("?{i}"))
            .collect::<Vec<_>>()
            .join(", ");

        let sql = format!(
            "{SELECT} WHERE media_file_id IN ({placeholders})
             ORDER BY media_file_id, language, path"
        );

        let mut query = sqlx::query_as::<_, ExternalSubtitleRow>(&sql);
        for id in chunk {
            query = query.bind(id);
        }

        out.extend(query.fetch_all(db.pool()).await?);
    }

    Ok(out)
}

pub async fn find(db: &Db, id: &str) -> Result<Option<ExternalSubtitleRow>, DbError> {
    let row = sqlx::query_as::<_, ExternalSubtitleRow>(&format!("{SELECT} WHERE id = ?1"))
        .bind(id)
        .fetch_optional(db.pool())
        .await?;

    Ok(row)
}

/// Drops rows for a file whose sidecar is no longer on disk. Called with the
/// paths the scan just saw.
///
/// An empty `keep` list deletes every row for that file. That is intentional
/// when all sidecars vanished. Callers must pass the paths just discovered,
/// never an accidentally empty list on a normal rescan that found sidecars.
pub async fn prune_for_file(db: &Db, media_file_id: &str, keep: &[String]) -> Result<u64, DbError> {
    let mut query = String::from("DELETE FROM external_subtitles WHERE media_file_id = ?1");

    for index in 0..keep.len() {
        query.push_str(&format!(" AND path <> ?{}", index + 2));
    }

    let mut statement = sqlx::query(&query).bind(media_file_id);
    for path in keep {
        statement = statement.bind(path);
    }

    Ok(statement.execute(db.pool()).await?.rows_affected())
}
