//! Port of `lib/mydia/jobs/file_analysis.ex`.
//!
//! Recurring worker that fills tech metadata (resolution, codec,
//! duration, bitrate, ...) for `media_files` rows the import path
//! leaves at `analyzed_at IS NULL`. The ffprobe work lives in
//! [`mydia_rs_library::FileAnalyzer`]; this worker is the batcher.
//!
//! Post-U12 cutover: SeaORM-native against `media_files`. The
//! duration / codec / resolution write back is deferred to a later
//! unit that lifts the analysis result into the model layer — for
//! now this worker only stamps `analyzed_at` and bumps
//! `analysis_attempts`, matching the prior cutover-window shape.

use apalis::prelude::Data;
use chrono::Utc;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{
    ColumnTrait, Condition, DatabaseConnection, EntityTrait, QueryFilter, QueryOrder, QuerySelect,
};
use serde::{Deserialize, Serialize};

use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_entities::media_files;
use mydia_rs_library::FileAnalyzer;

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

async fn fetch_unanalyzed_paths(
    db: &DatabaseConnection,
    batch_size: usize,
    max_attempts: u32,
) -> Result<Vec<(UuidText, String)>, JobsError> {
    let limit = u64::try_from(batch_size).unwrap_or(50);
    let attempts = i32::try_from(max_attempts).unwrap_or(i32::MAX);
    let rows = media_files::Entity::find()
        .filter(media_files::Column::AnalyzedAt.is_null())
        .filter(media_files::Column::AnalysisAttempts.lt(attempts))
        .filter(media_files::Column::Path.is_not_null())
        .order_by_asc(media_files::Column::InsertedAt)
        .limit(limit)
        .all(db)
        .await?;
    Ok(rows
        .into_iter()
        .filter_map(|row| row.path.map(|p| (row.id, p)))
        .collect())
}

async fn apply_analysis(
    db: &DatabaseConnection,
    id: &UuidText,
    _analysis: &mydia_rs_library::FileAnalysis,
) -> Result<(), JobsError> {
    // The full `apply_analysis` path writes resolution / codec /
    // duration / bitrate / hdr / audio-tracks columns. The
    // `media_files` entity here doesn't expose a `duration` column
    // (the Phoenix schema stores it on the `metadata` JSON column),
    // so for the cutover-window shape we stamp `analyzed_at` + bump
    // `analysis_attempts` only. The wider write surface lifts when
    // the metadata-encoding helper lands.
    let backend = db.get_database_backend();
    let analyzed_at = DateTimeSecs::from(Utc::now());
    media_files::Entity::update_many()
        .col_expr(
            media_files::Column::AnalyzedAt,
            analyzed_at.into_simple_expr(backend),
        )
        .col_expr(
            media_files::Column::AnalysisAttempts,
            Expr::col(media_files::Column::AnalysisAttempts).add(1),
        )
        .filter(
            Condition::all()
                .add(Expr::col(media_files::Column::Id).eq((*id).into_simple_expr(backend)))
                .add(media_files::Column::AnalyzedAt.is_null()),
        )
        .exec(db)
        .await?;
    Ok(())
}

async fn increment_attempts(db: &DatabaseConnection, id: &UuidText) -> Result<(), JobsError> {
    let backend = db.get_database_backend();
    media_files::Entity::update_many()
        .col_expr(
            media_files::Column::AnalysisAttempts,
            Expr::col(media_files::Column::AnalysisAttempts).add(1),
        )
        .filter(Expr::col(media_files::Column::Id).eq((*id).into_simple_expr(backend)))
        .exec(db)
        .await?;
    Ok(())
}
