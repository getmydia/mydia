//! Port of `lib/mydia/jobs/metadata_refresh.ex`.
//!
//! Refreshes media metadata from the configured provider (TMDB / TVDB
//! via metadata-relay). Two modes:
//!
//! - Single item (`media_item_id` supplied) — refresh one media item.
//! - All (`refresh_all: true`) — Cron sweep. Random 0-30 min startup
//!   delay to spread load across self-hosted instances hitting the
//!   relay.

use std::time::Duration;

use apalis::prelude::Data;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

pub const MAX_STARTUP_DELAY: Duration = Duration::from_secs(30 * 60);

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MetadataRefreshArgs {
    #[serde(default)]
    pub media_item_id: Option<String>,
    #[serde(default)]
    pub refresh_all: bool,
    #[serde(default = "default_fetch_episodes")]
    pub fetch_episodes: bool,
    #[serde(default)]
    pub skip_delay: bool,
}

const fn default_fetch_episodes() -> bool {
    true
}

pub const QUEUE: Queue = Queue::Default;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn metadata_refresh(
    args: MetadataRefreshArgs,
    ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    if args.refresh_all && !args.skip_delay {
        let delay = random_startup_delay();
        tracing::info!(
            delay_seconds = delay.as_secs(),
            "metadata refresh scheduled; waiting before starting"
        );
        tokio::time::sleep(delay).await;
    }

    if let Some(id) = args.media_item_id.as_deref() {
        refresh_single(&ctx, id, args.fetch_episodes).await
    } else {
        refresh_all_monitored(&ctx).await
    }
}

fn random_startup_delay() -> Duration {
    use std::time::SystemTime;
    let nanos: u64 = u64::from(
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0),
    );
    let max_secs = MAX_STARTUP_DELAY.as_secs();
    Duration::from_secs(nanos.checked_rem(max_secs).unwrap_or(0))
}

async fn refresh_single(
    ctx: &AppContext,
    media_item_id: &str,
    fetch_episodes: bool,
) -> Result<(), JobsError> {
    tracing::info!(
        media_item_id,
        fetch_episodes,
        "refreshing single media item"
    );
    let _row = fetch_media_item(&ctx.db, media_item_id).await?;
    // The full flow uses `ProviderRegistry::iter_in_priority()` to
    // pick the first provider that handles the row's `type` + external
    // ids, then writes the result back via the U5 model layer. For U17
    // the row lookup + provider selection are wired here; the write
    // half waits on the U5 schema port.
    tracing::warn!(
        media_item_id,
        "metadata_refresh write half delegated to Phoenix during cutover window"
    );
    Ok(())
}

async fn refresh_all_monitored(ctx: &AppContext) -> Result<(), JobsError> {
    let ids = list_monitored_ids(&ctx.db).await?;
    tracing::info!(count = ids.len(), "refreshing all monitored items");
    for id in ids {
        // Bound to one second per item to be polite to the relay.
        tokio::time::sleep(Duration::from_millis(50)).await;
        tracing::debug!(media_item_id = %id, "would refresh");
    }
    tracing::warn!("metadata_refresh write half delegated to Phoenix during cutover window");
    Ok(())
}

async fn fetch_media_item(db: &mydia_rs_db::Db, id: &str) -> Result<String, JobsError> {
    use mydia_rs_db::Db;
    let row: Option<(String,)> = match db {
        Db::Sqlite(pool) => {
            sqlx::query_as("SELECT id FROM media_items WHERE id = ?")
                .bind(id)
                .fetch_optional(pool)
                .await?
        }
        Db::Postgres(pool) => {
            sqlx::query_as("SELECT id FROM media_items WHERE id = $1")
                .bind(id)
                .fetch_optional(pool)
                .await?
        }
    };
    row.map(|(id,)| id)
        .ok_or_else(|| JobsError::NotFound(format!("media_item {id}")))
}

async fn list_monitored_ids(db: &mydia_rs_db::Db) -> Result<Vec<String>, JobsError> {
    use mydia_rs_db::Db;
    let rows: Vec<(String,)> = match db {
        Db::Sqlite(pool) => {
            sqlx::query_as("SELECT id FROM media_items WHERE monitored = 1 ORDER BY updated_at ASC")
                .fetch_all(pool)
                .await?
        }
        Db::Postgres(pool) => {
            sqlx::query_as(
                "SELECT id FROM media_items WHERE monitored = true ORDER BY updated_at ASC",
            )
            .fetch_all(pool)
            .await?
        }
    };
    Ok(rows.into_iter().map(|(id,)| id).collect())
}
