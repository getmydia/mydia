//! Port of `lib/mydia/jobs/movie_search.ex` (~756 LOC in Phoenix).
//!
//! Searches indexers for movie releases and initiates downloads for
//! the best match. Two modes:
//!
//! - `"all_monitored"` — Cron-driven sweep of every monitored movie
//!   without files.
//! - `"specific"` — UI-triggered single-movie search by `media_item_id`.
//!
//! The ranking and scoring live in
//! [`mydia_rs_indexers::release_ranker`] and
//! [`mydia_rs_indexers::search_scorer`]; the indexer registry lives on
//! the [`AppContext`].

use apalis::prelude::Data;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MovieSearchArgs {
    /// `"all_monitored"` or `"specific"`. Phoenix accepts both with the
    /// same string union; Rust mirrors verbatim.
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub media_item_id: Option<String>,
    #[serde(default)]
    pub min_seeders: Option<i32>,
    #[serde(default)]
    pub size_range: Option<serde_json::Value>,
    #[serde(default)]
    pub blocked_tags: Option<Vec<String>>,
    #[serde(default)]
    pub preferred_tags: Option<Vec<String>>,
}

pub const QUEUE: Queue = Queue::Search;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn movie_search(args: MovieSearchArgs, ctx: Data<AppContext>) -> Result<(), JobsError> {
    let mode = args.mode.as_deref().unwrap_or("all_monitored");
    tracing::info!(
        mode,
        media_item_id = args.media_item_id.as_deref().unwrap_or(""),
        "starting movie search"
    );

    match mode {
        "all_monitored" => search_all_monitored(&ctx).await,
        "specific" => match args.media_item_id.as_deref() {
            Some(id) => search_specific(&ctx, id, &args).await,
            None => Err(JobsError::WorkerError(
                "specific mode requires media_item_id".into(),
            )),
        },
        other => Err(JobsError::WorkerError(format!("unknown mode: {other}"))),
    }
}

async fn search_all_monitored(ctx: &AppContext) -> Result<(), JobsError> {
    let movies = monitored_movies_without_files(&ctx.db).await?;
    tracing::info!(count = movies.len(), "found monitored movies without files");

    // The full flow per movie:
    //   1. Pull quality profile + indexer config (re-resolved from DB)
    //   2. Build a SearchOpts and fan-out to every enabled indexer
    //      adapter via `ctx.indexers.adapter(kind)`
    //   3. Merge results, run `ReleaseRanker::rank_all`, drop blacklisted
    //   4. If a winner exists: enqueue a `MediaImport`-precursor via the
    //      download client registry
    //
    // Steps 1, 3, 4 require the U5 model layer for quality profiles
    // and download persistence. The ranker building block is already
    // in `mydia_rs_indexers::release_ranker::rank_all` and gets
    // wired in here once the row writes land.
    for id in &movies {
        tracing::debug!(media_item_id = %id, "would search indexers");
    }
    tracing::warn!(
        count = movies.len(),
        "movie_search release acquisition delegated to Phoenix during cutover window"
    );
    Ok(())
}

async fn search_specific(
    _ctx: &AppContext,
    media_item_id: &str,
    args: &MovieSearchArgs,
) -> Result<(), JobsError> {
    tracing::info!(
        media_item_id,
        min_seeders = args.min_seeders.unwrap_or(0),
        "searching for specific movie"
    );
    tracing::warn!(
        media_item_id,
        "movie_search specific-mode delegated to Phoenix during cutover window"
    );
    Ok(())
}

async fn monitored_movies_without_files(db: &mydia_rs_db::Db) -> Result<Vec<String>, JobsError> {
    use mydia_rs_db::Db;
    let rows: Vec<(String,)> = match db {
        Db::Sqlite(pool) => {
            sqlx::query_as(
                "SELECT m.id FROM media_items m \
             LEFT JOIN media_files f ON f.media_item_id = m.id \
             WHERE m.type = 'movie' AND m.monitored = 1 AND f.id IS NULL",
            )
            .fetch_all(pool)
            .await?
        }
        Db::Postgres(pool) => {
            sqlx::query_as(
                "SELECT m.id FROM media_items m \
             LEFT JOIN media_files f ON f.media_item_id = m.id \
             WHERE m.type = 'movie' AND m.monitored = true AND f.id IS NULL",
            )
            .fetch_all(pool)
            .await?
        }
    };
    Ok(rows.into_iter().map(|(id,)| id).collect())
}
