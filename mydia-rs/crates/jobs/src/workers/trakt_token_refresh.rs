//! Port of `lib/mydia/jobs/trakt_token_refresh.ex`.
//!
//! Proactively refreshes Trakt OAuth tokens that expire within
//! `expiry_window_days` (default 7). Cron-scheduled daily at 06:00 UTC.
//!
//! The actual refresh call goes through
//! [`mydia_rs_integrations::trakt::TraktClient`], which proxies the call
//! through the metadata-relay (relay holds the `client_id`/`client_secret`).

use apalis::prelude::Data;
use chrono::{Duration, Utc};
use mydia_rs_integrations::trakt::TraktClient;
use serde::{Deserialize, Serialize};

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

/// Default expiry window in days. Mirrors Phoenix's
/// `list_integrations_needing_refresh(7)` call.
pub const DEFAULT_EXPIRY_WINDOW_DAYS: i64 = 7;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TraktTokenRefreshArgs {
    /// Override the expiry window. Useful for tests; cron-driven runs
    /// always use the default.
    #[serde(default)]
    pub expiry_window_days: Option<i64>,
}

pub const QUEUE: Queue = Queue::Integrations;
pub const MAX_ATTEMPTS: u32 = 3;

pub async fn trakt_token_refresh(
    args: TraktTokenRefreshArgs,
    ctx: Data<AppContext>,
) -> Result<(), JobsError> {
    let window = args
        .expiry_window_days
        .unwrap_or(DEFAULT_EXPIRY_WINDOW_DAYS);

    let candidates = list_integrations_needing_refresh(&ctx.db, window).await?;
    tracing::info!(
        count = candidates.len(),
        "checking integrations for token refresh"
    );

    // The client base URL is resolved from `MetadataRelayConfig` at boot
    // — for U17 we accept that it lives behind an env var checked by
    // `TraktClient::new`. Workers that hit external services should
    // never embed the relay URL.
    let base_url = std::env::var("MYDIA_METADATA_RELAY_URL")
        .unwrap_or_else(|_| "https://metadata-relay.getmydia.com".to_owned());
    let client = TraktClient::new(base_url)
        .map_err(|err| JobsError::WorkerError(format!("trakt client init: {err}")))?;

    let mut refreshed = 0u32;
    let mut failed = 0u32;
    for integration in candidates {
        match refresh_one(&client, &ctx.db, &integration).await {
            Ok(()) => {
                refreshed += 1;
                tracing::info!(user_id = %integration.user_id, "refreshed Trakt token");
            }
            Err(err) => {
                failed += 1;
                tracing::warn!(
                    user_id = %integration.user_id,
                    error = %err,
                    "failed to refresh Trakt token"
                );
            }
        }
    }

    tracing::info!(refreshed, failed, "trakt token refresh sweep complete");
    Ok(())
}

/// Row shape selected from `user_integrations`. Kept narrow on purpose;
/// the full struct lives in [`mydia_rs_integrations::user_integration`]
/// but the refresh path only needs three fields.
struct TraktIntegrationRow {
    id: String,
    user_id: String,
    refresh_token: Option<String>,
}

async fn list_integrations_needing_refresh(
    db: &mydia_rs_db::Db,
    window_days: i64,
) -> Result<Vec<TraktIntegrationRow>, JobsError> {
    use mydia_rs_db::Db;
    let cutoff = Utc::now() + Duration::days(window_days);
    match db {
        Db::Sqlite(pool) => {
            let rows: Vec<(String, String, Option<String>)> = sqlx::query_as(
                "SELECT id, user_id, refresh_token FROM user_integrations \
                 WHERE provider = 'trakt' \
                   AND enabled = 1 \
                   AND token_expires_at IS NOT NULL \
                   AND token_expires_at < ?",
            )
            .bind(cutoff.to_rfc3339())
            .fetch_all(pool)
            .await?;
            Ok(rows
                .into_iter()
                .map(|(id, user_id, refresh_token)| TraktIntegrationRow {
                    id,
                    user_id,
                    refresh_token,
                })
                .collect())
        }
        Db::Postgres(pool) => {
            let rows: Vec<(String, String, Option<String>)> = sqlx::query_as(
                "SELECT id, user_id, refresh_token FROM user_integrations \
                 WHERE provider = 'trakt' \
                   AND enabled = true \
                   AND token_expires_at IS NOT NULL \
                   AND token_expires_at < $1",
            )
            .bind(cutoff)
            .fetch_all(pool)
            .await?;
            Ok(rows
                .into_iter()
                .map(|(id, user_id, refresh_token)| TraktIntegrationRow {
                    id,
                    user_id,
                    refresh_token,
                })
                .collect())
        }
    }
}

async fn refresh_one(
    client: &TraktClient,
    db: &mydia_rs_db::Db,
    integration: &TraktIntegrationRow,
) -> Result<(), JobsError> {
    use mydia_rs_db::Db;
    let refresh_token = integration
        .refresh_token
        .as_deref()
        .ok_or_else(|| JobsError::WorkerError("integration missing refresh token".into()))?;
    let new_token = client
        .refresh_token(refresh_token)
        .await
        .map_err(|err| JobsError::WorkerError(format!("trakt refresh: {err}")))?;

    // Persist the new tokens. Trakt returns expiry in seconds-from-now;
    // default to a 90-day expiry when the API doesn't supply one (the
    // long Trakt default).
    let expires_in = new_token.expires_in.unwrap_or(7_776_000).max(0);
    let expires_at = Utc::now() + Duration::seconds(expires_in);
    match db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "UPDATE user_integrations \
                 SET access_token = ?, refresh_token = ?, token_expires_at = ? \
                 WHERE id = ?",
            )
            .bind(&new_token.access_token)
            .bind(&new_token.refresh_token)
            .bind(expires_at.to_rfc3339())
            .bind(&integration.id)
            .execute(pool)
            .await?;
        }
        Db::Postgres(pool) => {
            sqlx::query(
                "UPDATE user_integrations \
                 SET access_token = $1, refresh_token = $2, token_expires_at = $3 \
                 WHERE id = $4",
            )
            .bind(&new_token.access_token)
            .bind(&new_token.refresh_token)
            .bind(expires_at)
            .bind(&integration.id)
            .execute(pool)
            .await?;
        }
    }
    Ok(())
}
