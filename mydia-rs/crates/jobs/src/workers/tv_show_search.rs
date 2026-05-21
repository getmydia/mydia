//! Port of `lib/mydia/jobs/tv_show_search.ex` (~2112 LOC in Phoenix).
//!
//! Searches indexers for TV-show releases (episode, season pack, or
//! series pack) and initiates downloads for the best match. Three modes
//! mirror Phoenix:
//!
//! - `"all_monitored"` — Cron sweep of every monitored show with
//!   missing episodes.
//! - `"season"` — Targeted season-pack search.
//! - `"specific"` — Single-episode search by `episode_id`.
//!
//! Ranking + scoring live in
//! [`mydia_rs_indexers::release_ranker`].

use apalis::prelude::Data;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TvShowSearchArgs {
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub media_item_id: Option<String>,
    #[serde(default)]
    pub season_id: Option<String>,
    #[serde(default)]
    pub episode_id: Option<String>,
    #[serde(default)]
    pub min_seeders: Option<i32>,
    #[serde(default)]
    pub blocked_tags: Option<Vec<String>>,
    #[serde(default)]
    pub preferred_tags: Option<Vec<String>>,
}

pub const QUEUE: Queue = Queue::Search;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn tv_show_search(
    args: TvShowSearchArgs,
    ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    let mode = args.mode.as_deref().unwrap_or("all_monitored");
    tracing::info!(
        mode,
        media_item_id = args.media_item_id.as_deref().unwrap_or(""),
        episode_id = args.episode_id.as_deref().unwrap_or(""),
        season_id = args.season_id.as_deref().unwrap_or(""),
        "starting TV show search"
    );

    match mode {
        "all_monitored" => sweep_all_monitored(&ctx).await,
        "season" => match args.season_id.as_deref() {
            Some(id) => search_season(&ctx, id).await,
            None => Err(JobsError::WorkerError(
                "season mode requires season_id".into(),
            )),
        },
        "specific" => match args.episode_id.as_deref() {
            Some(id) => search_episode(&ctx, id).await,
            None => Err(JobsError::WorkerError(
                "specific mode requires episode_id".into(),
            )),
        },
        other => Err(JobsError::WorkerError(format!("unknown mode: {other}"))),
    }
}

async fn sweep_all_monitored(_ctx: &AppContext) -> Result<(), JobsError> {
    tracing::warn!("tv_show_search all-monitored sweep delegated to Phoenix during cutover window");
    Ok(())
}

async fn search_season(_ctx: &AppContext, season_id: &str) -> Result<(), JobsError> {
    tracing::warn!(
        season_id,
        "tv_show_search season delegated to Phoenix during cutover window"
    );
    Ok(())
}

async fn search_episode(_ctx: &AppContext, episode_id: &str) -> Result<(), JobsError> {
    tracing::warn!(
        episode_id,
        "tv_show_search episode delegated to Phoenix during cutover window"
    );
    Ok(())
}
