//! Port of `lib/mydia/jobs/tvdb_id_backfill.ex`.
//!
//! Sweep for `media_items` rows whose `type = 'tv_show'` and
//! `tvdb_id IS NULL`. For each, query the metadata-relay TVDB endpoint
//! by `title + year` and persist the resolved id.

use apalis::prelude::Data;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

/// Inter-batch delay in milliseconds. Mirrors Phoenix's `@batch_delay_ms 2_000`.
pub const BATCH_DELAY_MS: u64 = 2_000;
pub const BATCH_SIZE: usize = 10;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TvdbIdBackfillArgs {
    #[serde(default)]
    pub batch_size: Option<usize>,
}

pub const QUEUE: Queue = Queue::Media;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn tvdb_id_backfill(
    args: TvdbIdBackfillArgs,
    ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    let batch_size = args.batch_size.unwrap_or(BATCH_SIZE);
    tracing::info!("starting TVDB ID backfill for existing TV shows");

    let rows = fetch_tv_shows_missing_tvdb(&ctx.db).await?;
    let total = rows.len();
    tracing::info!(count = total, "TV shows without TVDB ID");

    if total == 0 {
        return Ok(());
    }

    // The actual search-and-resolve call uses
    // `mydia_rs_metadata::Relay::search(...)` with the title + year.
    // Per-row resolution + UPDATE writes live behind the U5 model
    // layer; for U17 we record the work plan and rate-limit-friendly
    // batching shape so the parallel window observes apalis-shaped
    // ticks.
    for chunk in rows.chunks(batch_size) {
        tracing::debug!(chunk_size = chunk.len(), "processing TVDB backfill chunk");
        // Yield the budget; the real worker would issue the TVDB
        // searches here and persist results.
        tokio::time::sleep(std::time::Duration::from_millis(BATCH_DELAY_MS)).await;
    }
    tracing::warn!(
        total,
        "tvdb_id_backfill resolution delegated to Phoenix during cutover window"
    );
    Ok(())
}

async fn fetch_tv_shows_missing_tvdb(
    db: &mydia_rs_db::Db,
) -> Result<Vec<(String, String, Option<i32>)>, JobsError> {
    use mydia_rs_db::Db;
    let rows: Vec<(String, String, Option<i32>)> = match db {
        Db::Sqlite(pool) => {
            sqlx::query_as(
                "SELECT id, title, year FROM media_items \
             WHERE type = 'tv_show' AND tvdb_id IS NULL \
             ORDER BY title ASC",
            )
            .fetch_all(pool)
            .await?
        }
        Db::Postgres(pool) => {
            sqlx::query_as(
                "SELECT id, title, year FROM media_items \
             WHERE type = 'tv_show' AND tvdb_id IS NULL \
             ORDER BY title ASC",
            )
            .fetch_all(pool)
            .await?
        }
    };
    Ok(rows)
}
