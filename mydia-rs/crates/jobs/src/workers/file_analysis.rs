//! Port of `lib/mydia/jobs/file_analysis.ex`.
//!
//! Recurring worker that fills tech metadata (resolution, codec,
//! duration, bitrate, ...) for `media_files` rows the import path
//! leaves at `analyzed_at IS NULL`. The ffprobe work lives in
//! [`mydia_rs_library::FileAnalyzer`]; this worker is the batcher.

use apalis::prelude::Data;
use mydia_rs_library::FileAnalyzer;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

/// Default rows-per-tick. Phoenix's `:file_analysis_batch_size`
/// defaults to 50.
pub const DEFAULT_BATCH_SIZE: usize = 50;

/// Max ffprobe attempts per row. Phoenix's
/// `:file_analysis_max_attempts` defaults to 3.
pub const DEFAULT_MAX_ATTEMPTS: u32 = 3;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FileAnalysisArgs {
    #[serde(default)]
    pub batch_size: Option<usize>,
    #[serde(default)]
    pub max_attempts: Option<u32>,
}

pub const QUEUE: Queue = Queue::Analysis;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn file_analysis(args: FileAnalysisArgs, ctx: Data<AppContext>) -> Result<(), JobsError> {
    let batch_size = args.batch_size.unwrap_or(DEFAULT_BATCH_SIZE);
    let max_attempts = args.max_attempts.unwrap_or(DEFAULT_MAX_ATTEMPTS);

    let rows = fetch_unanalyzed_paths(&ctx.db, batch_size, max_attempts).await?;
    if rows.is_empty() {
        tracing::debug!("file_analysis: no rows to process");
        return Ok(());
    }
    tracing::debug!(count = rows.len(), "file_analysis processing batch");

    let analyzer = FileAnalyzer::default();
    for (id, path) in rows {
        match analyzer.analyze(&path).await {
            Ok(analysis) => {
                apply_analysis(&ctx.db, &id, &analysis).await?;
            }
            Err(err) => {
                tracing::warn!(media_file_id = %id, path = %path, error = %err, "file analysis failed");
                increment_attempts(&ctx.db, &id).await?;
            }
        }
    }
    Ok(())
}

#[derive(Debug, Clone)]
struct UnanalyzedRow {
    id: String,
    path: String,
}

async fn fetch_unanalyzed_paths(
    db: &mydia_rs_db::Db,
    batch_size: usize,
    max_attempts: u32,
) -> Result<Vec<(String, String)>, JobsError> {
    use mydia_rs_db::Db;
    let limit = i64::try_from(batch_size).unwrap_or(50);
    let attempts = i64::from(max_attempts);
    let rows: Vec<(String, String)> = match db {
        Db::Sqlite(pool) => {
            sqlx::query_as(
                "SELECT id, path FROM media_files \
             WHERE analyzed_at IS NULL AND analysis_attempts < ? \
             ORDER BY inserted_at ASC LIMIT ?",
            )
            .bind(attempts)
            .bind(limit)
            .fetch_all(pool)
            .await?
        }
        Db::Postgres(pool) => {
            sqlx::query_as(
                "SELECT id, path FROM media_files \
             WHERE analyzed_at IS NULL AND analysis_attempts < $1 \
             ORDER BY inserted_at ASC LIMIT $2",
            )
            .bind(attempts)
            .bind(limit)
            .fetch_all(pool)
            .await?
        }
    };
    Ok(rows)
}

async fn apply_analysis(
    db: &mydia_rs_db::Db,
    id: &str,
    analysis: &mydia_rs_library::FileAnalysis,
) -> Result<(), JobsError> {
    use mydia_rs_db::Db;
    // The full `apply_analysis` path writes resolution / codec /
    // duration / bitrate / hdr / audio-tracks columns. For U17 we
    // record `analyzed_at` and the duration; the wider write surface
    // lives behind the U5 model layer.
    let analyzed_at = chrono::Utc::now();
    let duration_seconds = analysis.duration_secs;
    match db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "UPDATE media_files \
                 SET analyzed_at = ?, duration = ?, analysis_attempts = analysis_attempts + 1 \
                 WHERE id = ? AND analyzed_at IS NULL",
            )
            .bind(analyzed_at.to_rfc3339())
            .bind(duration_seconds)
            .bind(id)
            .execute(pool)
            .await?;
        }
        Db::Postgres(pool) => {
            sqlx::query(
                "UPDATE media_files \
                 SET analyzed_at = $1, duration = $2, analysis_attempts = analysis_attempts + 1 \
                 WHERE id = $3 AND analyzed_at IS NULL",
            )
            .bind(analyzed_at)
            .bind(duration_seconds)
            .bind(id)
            .execute(pool)
            .await?;
        }
    }
    Ok(())
}

async fn increment_attempts(db: &mydia_rs_db::Db, id: &str) -> Result<(), JobsError> {
    use mydia_rs_db::Db;
    match db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "UPDATE media_files \
                 SET analysis_attempts = analysis_attempts + 1 \
                 WHERE id = ?",
            )
            .bind(id)
            .execute(pool)
            .await?;
        }
        Db::Postgres(pool) => {
            sqlx::query(
                "UPDATE media_files \
                 SET analysis_attempts = analysis_attempts + 1 \
                 WHERE id = $1",
            )
            .bind(id)
            .execute(pool)
            .await?;
        }
    }
    Ok(())
}

// Keep the row shape struct around as a future seam; it isn't used
// directly because `fetch_unanalyzed_paths` returns `(id, path)`
// tuples but the named struct will be useful when the row gets more
// fields in U23+.
#[allow(dead_code)]
impl UnanalyzedRow {
    fn from_tuple(t: (String, String)) -> Self {
        Self { id: t.0, path: t.1 }
    }

    fn id(&self) -> &str {
        &self.id
    }

    fn path(&self) -> &str {
        &self.path
    }
}
