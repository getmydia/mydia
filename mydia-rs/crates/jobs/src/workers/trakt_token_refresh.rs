//! Port of `lib/mydia/jobs/trakt_token_refresh.ex`.
//!
//! Proactively refreshes Trakt OAuth tokens that expire within
//! `expiry_window_days` (default 7). Cron-scheduled daily at 06:00 UTC.
//!
//! The actual refresh call goes through
//! [`mydia_rs_integrations::trakt::TraktClient`], which proxies the call
//! through the metadata-relay (relay holds the `client_id`/`client_secret`).
//!
//! Post-U12 cutover: SeaORM-native against `user_integrations`. The
//! token-expiry cutoff binds through `DateTimeSecs::into_simple_expr`
//! so the Postgres `$N::timestamptz` cast is applied automatically.

use apalis::prelude::Data;
use chrono::{Duration, Utc};
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{ColumnTrait, DatabaseConnection, EntityTrait, QueryFilter};
use serde::{Deserialize, Serialize};

use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_entities::user_integrations;
use mydia_rs_integrations::trakt::TraktClient;

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
    // — accept that it lives behind an env var checked by
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
    id: UuidText,
    user_id: UuidText,
    refresh_token: Option<String>,
}

async fn list_integrations_needing_refresh(
    db: &DatabaseConnection,
    window_days: i64,
) -> Result<Vec<TraktIntegrationRow>, JobsError> {
    let backend = db.get_database_backend();
    let cutoff = DateTimeSecs::from(Utc::now() + Duration::days(window_days));
    let rows = user_integrations::Entity::find()
        .filter(user_integrations::Column::Provider.eq("trakt"))
        .filter(user_integrations::Column::Enabled.eq(true))
        .filter(user_integrations::Column::TokenExpiresAt.is_not_null())
        .filter(
            Expr::col(user_integrations::Column::TokenExpiresAt)
                .lt(cutoff.into_simple_expr(backend)),
        )
        .all(db)
        .await?;
    Ok(rows
        .into_iter()
        .map(|row| TraktIntegrationRow {
            id: row.id,
            user_id: row.user_id,
            refresh_token: row.refresh_token,
        })
        .collect())
}

async fn refresh_one(
    client: &TraktClient,
    db: &DatabaseConnection,
    integration: &TraktIntegrationRow,
) -> Result<(), JobsError> {
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
    let expires_in = std::cmp::Ord::max(new_token.expires_in.unwrap_or(7_776_000), 0);
    let expires_at = DateTimeSecs::from(Utc::now() + Duration::seconds(expires_in));
    let backend = db.get_database_backend();
    user_integrations::Entity::update_many()
        .col_expr(
            user_integrations::Column::AccessToken,
            Expr::value(new_token.access_token.clone()),
        )
        .col_expr(
            user_integrations::Column::RefreshToken,
            Expr::value(new_token.refresh_token.clone()),
        )
        .col_expr(
            user_integrations::Column::TokenExpiresAt,
            expires_at.into_simple_expr(backend),
        )
        .filter(
            Expr::col(user_integrations::Column::Id)
                .eq(integration.id.clone().into_simple_expr(backend)),
        )
        .exec(db)
        .await?;
    Ok(())
}
