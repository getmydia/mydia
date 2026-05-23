//! `/api/v1/indexers/*` — indexer config + health.
//!
//! Port of `MydiaWeb.Api.IndexerController` from
//! `lib/mydia_web/controllers/api/indexer_controller.ex`. `index` and
//! `show` query the `indexer_configs` table and return the
//! Phoenix-shaped JSON projection. The `health`, `rate_limit_stats`,
//! and `consecutive_failures` fields are placeholders until the
//! `mydia_rs_indexers::health` runtime cache ports — the wire shape
//! matches Phoenix so the operator UI stays consistent.
//!
//! `test`, `refresh`, and `reset_failures` remain 501 — they need
//! the same runtime cache to manipulate, which is its own follow-up.

use axum::{
    extract::Path,
    http::StatusCode,
    middleware::from_fn,
    response::{IntoResponse, Response},
    routing::{get, post},
    Extension, Json, Router,
};
use serde_json::json;

use crate::api::auth_layer::api_key_auth;
use crate::api::v1::{json_error, not_implemented};
use crate::WebState;

pub fn router() -> Router {
    Router::new()
        .route("/api/v1/indexers", get(index))
        .route("/api/v1/indexers/refresh", post(refresh))
        .route("/api/v1/indexers/{id}", get(show))
        .route("/api/v1/indexers/{id}/test", post(test))
        .route("/api/v1/indexers/{id}/reset-failures", post(reset_failures))
        .layer(from_fn(api_key_auth))
}

#[derive(sqlx::FromRow)]
struct IndexerRow {
    id: String,
    name: Option<String>,
    r#type: Option<String>,
    enabled: Option<bool>,
    priority: Option<i64>,
    base_url: Option<String>,
    api_key: Option<String>,
    indexer_ids: Option<String>,
    categories: Option<String>,
    rate_limit: Option<i64>,
    connection_settings: Option<String>,
}

async fn index(Extension(state): Extension<WebState>) -> Response {
    match list_indexers(&state).await {
        Ok(rows) => {
            let indexers: Vec<serde_json::Value> = rows.iter().map(serialize_summary).collect();
            let body = json!({ "data": indexers });
            (StatusCode::OK, Json(body)).into_response()
        }
        Err(err) => {
            tracing::error!(error = ?err, "indexer.index db error");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error")
        }
    }
}

async fn show(Extension(state): Extension<WebState>, Path(id): Path<String>) -> Response {
    match lookup_indexer(&state, &id).await {
        Ok(Some(row)) => {
            let body = json!({ "data": serialize_detail(&row) });
            (StatusCode::OK, Json(body)).into_response()
        }
        Ok(None) => json_error(StatusCode::NOT_FOUND, "Indexer not found"),
        Err(err) => {
            tracing::error!(error = ?err, id, "indexer.show db error");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error")
        }
    }
}

async fn test(Path(_id): Path<String>) -> Response {
    not_implemented("U33.indexer.test")
}

async fn refresh() -> Response {
    not_implemented("U33.indexer.refresh")
}

async fn reset_failures(Path(_id): Path<String>) -> Response {
    not_implemented("U33.indexer.reset_failures")
}

async fn list_indexers(state: &WebState) -> Result<Vec<IndexerRow>, sqlx::Error> {
    use mydia_rs_db::Db;

    let sql = "
        SELECT id, name, type, enabled, priority, base_url, api_key, indexer_ids, \
               categories, rate_limit, connection_settings
        FROM indexer_configs
        ORDER BY priority ASC, name ASC
    ";

    match &state.db {
        Db::Sqlite(pool) => sqlx::query_as::<_, IndexerRow>(sql).fetch_all(pool).await,
        Db::Postgres(pool) => sqlx::query_as::<_, IndexerRow>(sql).fetch_all(pool).await,
    }
}

async fn lookup_indexer(state: &WebState, id: &str) -> Result<Option<IndexerRow>, sqlx::Error> {
    use mydia_rs_db::Db;

    let sql = "
        SELECT id, name, type, enabled, priority, base_url, api_key, indexer_ids, \
               categories, rate_limit, connection_settings
        FROM indexer_configs
        WHERE id = $1
        LIMIT 1
    ";

    match &state.db {
        Db::Sqlite(pool) => {
            let sql_sqlite = sql.replace("$1", "?");
            sqlx::query_as::<_, IndexerRow>(&sql_sqlite)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, IndexerRow>(sql)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
    }
}

fn serialize_summary(row: &IndexerRow) -> serde_json::Value {
    json!({
        "id": row.id,
        "name": row.name,
        "type": row.r#type,
        "enabled": row.enabled.unwrap_or(false),
        "priority": row.priority,
        "base_url": row.base_url,
        "rate_limit": row.rate_limit,
        "health": health_unknown(),
        "rate_limit_stats": rate_limit_stats_zero(),
        "consecutive_failures": 0,
    })
}

fn serialize_detail(row: &IndexerRow) -> serde_json::Value {
    // Mirror Phoenix's `api_key` redaction — show "***" when set, null
    // when absent. The operator UI presents the redacted marker as a
    // signal that a key is configured without exposing the secret.
    let api_key_redacted = row.api_key.as_ref().map(|_| "***");

    json!({
        "id": row.id,
        "name": row.name,
        "type": row.r#type,
        "enabled": row.enabled.unwrap_or(false),
        "priority": row.priority,
        "base_url": row.base_url,
        "api_key": api_key_redacted,
        "indexer_ids": row.indexer_ids,
        "categories": row.categories,
        "rate_limit": row.rate_limit,
        "connection_settings": row.connection_settings,
        "health": health_unknown(),
        "rate_limit_stats": rate_limit_stats_zero(),
        "consecutive_failures": 0,
    })
}

fn health_unknown() -> serde_json::Value {
    json!({ "status": "unknown" })
}

/// Placeholder rate-limit stats payload until the rate limiter ports.
/// Matches the Phoenix `RateLimiter.get_stats(id)` shape for a freshly
/// reset bucket so the operator UI's progress bars don't NaN.
fn rate_limit_stats_zero() -> serde_json::Value {
    json!({
        "requests_in_window": 0,
        "window_seconds": 60,
        "requests_remaining": null,
    })
}
