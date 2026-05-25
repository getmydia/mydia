//! `/api/v1/indexers/*` — indexer config + health.
//!
//! Port of `MydiaWeb.Api.IndexerController` from
//! `lib/mydia_web/controllers/api/indexer_controller.ex`. `index` and
//! `show` query the `indexer_configs` table and return the
//! Phoenix-shaped JSON projection. `health` is populated from the
//! [`IndexerProbeCache`] when the entry is still fresh; otherwise the
//! field renders `{"status": "unknown"}` so the operator UI shows a
//! neutral "not yet tested" badge until the next probe.
//!
//! `test` invalidates the cached entry then dispatches a fresh probe.
//! `refresh` calls `invalidate_all` so the next operator probe across
//! every indexer lands fresh. `reset_failures` zeros the
//! consecutive-failure counter for one indexer without dropping the
//! cached verdict. All three return Phoenix-shaped JSON.
//!
//! `rate_limit_stats` remains a stub (`requests_in_window: 0`) until
//! the [`mydia_rs_indexers::rate_limiter`] surface threads through
//! `WebState`. The wire shape matches Phoenix so existing clients
//! render unchanged.

use axum::{
    extract::Path,
    http::StatusCode,
    middleware::from_fn,
    response::{IntoResponse, Response},
    routing::{get, post},
    Extension, Json, Router,
};
use mydia_rs_indexers::adapter::{AdapterConfig, AdapterKind};
use serde_json::json;

use crate::api::auth_layer::api_key_auth;
use crate::api::v1::json_error;
use crate::indexer_probes::{IndexerProbeEntry, DEFAULT_TTL};
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

type IndexerRow = mydia_rs_entities::indexer_configs::Model;

async fn index(Extension(state): Extension<WebState>) -> Response {
    match list_indexers(&state).await {
        Ok(rows) => {
            let indexers: Vec<serde_json::Value> = rows
                .iter()
                .map(|row| {
                    let id_str = row.id.to_string();
                    let cached = state.indexer_probes.cached(&id_str);
                    let failures = state.indexer_probes.failure_count(&id_str);
                    let health = cached
                        .as_ref()
                        .map_or_else(health_unknown, serialize_health);
                    serialize_summary(row, &health, failures)
                })
                .collect();
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
            let id_str = row.id.to_string();
            let cached = state.indexer_probes.cached(&id_str);
            let failures = state.indexer_probes.failure_count(&id_str);
            let health = cached
                .as_ref()
                .map_or_else(health_unknown, serialize_health);
            let body = json!({ "data": serialize_detail(&row, &health, failures) });
            (StatusCode::OK, Json(body)).into_response()
        }
        Ok(None) => json_error(StatusCode::NOT_FOUND, "Indexer not found"),
        Err(err) => {
            tracing::error!(error = ?err, id, "indexer.show db error");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error")
        }
    }
}

/// `POST /api/v1/indexers/:id/test` — forced probe.
///
/// Mirrors Phoenix's `Mydia.Indexers.Health.check_health(id,
/// force: true)`: invalidate any cached entry first, then dispatch
/// a fresh probe through [`IndexerProbeCache::probe`]. Returns Phoenix's
/// `{"data": health}` shape, with 404 when the id is unknown and 500
/// on DB error.
async fn test(Extension(state): Extension<WebState>, Path(id): Path<String>) -> Response {
    match lookup_probe_target(&state, &id).await {
        Ok(Some(target)) => {
            // Drop the cached entry so `probe` runs fresh. We
            // intentionally keep the failure counter intact here —
            // operator-driven probes count toward the alert trail
            // exactly the same as background probes did.
            state.indexer_probes.invalidate(&id);
            let entry = probe_target(&state, &id, target).await;
            (
                StatusCode::OK,
                Json(json!({ "data": serialize_health(&entry) })),
            )
                .into_response()
        }
        Ok(None) => json_error(StatusCode::NOT_FOUND, "Indexer not found"),
        Err(err) => {
            tracing::error!(error = ?err, id, "indexer.test db error");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error")
        }
    }
}

/// `POST /api/v1/indexers/refresh` — bulk cache flush.
///
/// Mirrors Phoenix's `Health.refresh_all_indexers/0`. The Phoenix path
/// casts to a `GenServer` and fans out background tasks; our cache
/// invalidation is synchronous (the next probe will issue a fresh
/// network call) but the wire shape is preserved so clients written
/// against Phoenix see the same `{"message": "..."}` body.
async fn refresh(Extension(state): Extension<WebState>) -> Response {
    state.indexer_probes.invalidate_all();
    (
        StatusCode::ACCEPTED,
        Json(json!({ "message": "Health check refresh initiated" })),
    )
        .into_response()
}

/// `POST /api/v1/indexers/:id/reset-failures` — clear failure counter.
///
/// Mirrors Phoenix's `Health.reset_failures/1`. The cached verdict is
/// left in place (so operators can still see what the last probe said)
/// but the consecutive-failure counter is dropped to zero. Returns
/// `200` with Phoenix's `{"message": "..."}` body on success, `404`
/// when the indexer doesn't exist.
async fn reset_failures(Extension(state): Extension<WebState>, Path(id): Path<String>) -> Response {
    match indexer_exists(&state, &id).await {
        Ok(true) => {
            state.indexer_probes.reset_failures(&id);
            (
                StatusCode::OK,
                Json(json!({ "message": "Failure counter reset successfully" })),
            )
                .into_response()
        }
        Ok(false) => json_error(StatusCode::NOT_FOUND, "Indexer not found"),
        Err(err) => {
            tracing::error!(error = ?err, id, "indexer.reset_failures db error");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error")
        }
    }
}

/// Fields needed to dispatch a probe through the cache.
struct ProbeTarget {
    kind: String,
    name: String,
    base_url: String,
    api_key: Option<String>,
}

async fn lookup_probe_target(
    state: &WebState,
    id: &str,
) -> Result<Option<ProbeTarget>, sea_orm::DbErr> {
    use mydia_rs_db::types::UuidText;
    use mydia_rs_entities::indexer_configs;
    use sea_orm::entity::prelude::*;
    use sea_orm::sea_query::{Expr, ExprTrait};

    let Some(wrapper) = uuid::Uuid::parse_str(id).ok().map(UuidText::from) else {
        return Ok(None);
    };
    let backend = state.db.get_database_backend();
    let row = indexer_configs::Entity::find()
        .filter(Expr::col(indexer_configs::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .one(&state.db)
        .await?;
    Ok(row.map(|m| ProbeTarget {
        kind: m.r#type,
        name: m.name,
        base_url: m.base_url.unwrap_or_default(),
        api_key: m.api_key,
    }))
}

async fn indexer_exists(state: &WebState, id: &str) -> Result<bool, sea_orm::DbErr> {
    use mydia_rs_db::types::UuidText;
    use mydia_rs_entities::indexer_configs;
    use sea_orm::entity::prelude::*;
    use sea_orm::sea_query::{Expr, ExprTrait};

    let Some(wrapper) = uuid::Uuid::parse_str(id).ok().map(UuidText::from) else {
        return Ok(false);
    };
    let backend = state.db.get_database_backend();
    let count = indexer_configs::Entity::find()
        .filter(Expr::col(indexer_configs::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .count(&state.db)
        .await?;
    Ok(count > 0)
}

async fn probe_target(state: &WebState, id: &str, target: ProbeTarget) -> IndexerProbeEntry {
    let Some(kind) = parse_kind(&target.kind) else {
        // Unknown kind values short-circuit with a structured failure
        // so the operator sees "unsupported type" instead of an opaque
        // 500. We still record this on the cache so the next probe
        // skips the round-trip.
        let entry = IndexerProbeEntry {
            ok: false,
            message: format!("unsupported indexer kind {:?}", target.kind),
            ts: std::time::Instant::now(),
            consecutive_failures: state.indexer_probes.failure_count(id).saturating_add(1),
        };
        return entry;
    };

    let config = AdapterConfig {
        r#type: kind,
        name: target.name,
        base_url: target.base_url,
        api_key: target.api_key,
        options: serde_json::Value::Null,
        id: id.to_owned(),
        rate_limit: None,
    };
    state.indexer_probes.probe(id, kind, config).await
}

fn parse_kind(value: &str) -> Option<AdapterKind> {
    match value.to_ascii_lowercase().as_str() {
        "cardigann" => Some(AdapterKind::Cardigann),
        "prowlarr" => Some(AdapterKind::Prowlarr),
        "jackett" => Some(AdapterKind::Jackett),
        "nzbhydra2" | "nzbhydra" => Some(AdapterKind::Nzbhydra2),
        _ => None,
    }
}

/// Serialize a probe entry into Phoenix's `health_result` shape so the
/// REST surface returns the same fields Phoenix does. `consecutive_failures`
/// lives alongside `health` on the wire (matches `IndexerController.show`).
fn serialize_health(entry: &IndexerProbeEntry) -> serde_json::Value {
    let elapsed = entry.ts.elapsed();
    let checked_at = chrono::Utc::now() - chrono::Duration::from_std(elapsed).unwrap_or_default();
    let (status, error) = if entry.ok {
        ("healthy", serde_json::Value::Null)
    } else {
        (
            "unhealthy",
            serde_json::Value::String(entry.message.clone()),
        )
    };
    let details = if entry.ok {
        json!({ "message": entry.message })
    } else {
        json!({})
    };
    json!({
        "status": status,
        "checked_at": checked_at.to_rfc3339(),
        "details": details,
        "error": error,
        "ttl_seconds": DEFAULT_TTL.as_secs(),
    })
}

async fn list_indexers(state: &WebState) -> Result<Vec<IndexerRow>, sea_orm::DbErr> {
    use mydia_rs_entities::indexer_configs;
    use sea_orm::entity::prelude::*;
    use sea_orm::query::QueryOrder;

    indexer_configs::Entity::find()
        .order_by_asc(indexer_configs::Column::Priority)
        .order_by_asc(indexer_configs::Column::Name)
        .all(&state.db)
        .await
}

async fn lookup_indexer(state: &WebState, id: &str) -> Result<Option<IndexerRow>, sea_orm::DbErr> {
    use mydia_rs_db::types::UuidText;
    use mydia_rs_entities::indexer_configs;
    use sea_orm::entity::prelude::*;
    use sea_orm::sea_query::{Expr, ExprTrait};

    let Some(wrapper) = uuid::Uuid::parse_str(id).ok().map(UuidText::from) else {
        return Ok(None);
    };
    let backend = state.db.get_database_backend();
    indexer_configs::Entity::find()
        .filter(Expr::col(indexer_configs::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .one(&state.db)
        .await
}

fn serialize_summary(
    row: &IndexerRow,
    health: &serde_json::Value,
    consecutive_failures: u32,
) -> serde_json::Value {
    json!({
        "id": row.id.to_string(),
        "name": row.name,
        "type": row.r#type,
        "enabled": row.enabled.unwrap_or(false),
        "priority": row.priority,
        "base_url": row.base_url,
        "rate_limit": row.rate_limit,
        "health": health,
        "rate_limit_stats": rate_limit_stats_zero(),
        "consecutive_failures": consecutive_failures,
    })
}

fn serialize_detail(
    row: &IndexerRow,
    health: &serde_json::Value,
    consecutive_failures: u32,
) -> serde_json::Value {
    // Mirror Phoenix's `api_key` redaction — show "***" when set, null
    // when absent. The operator UI presents the redacted marker as a
    // signal that a key is configured without exposing the secret.
    let api_key_redacted = row.api_key.as_ref().map(|_| "***");

    json!({
        "id": row.id.to_string(),
        "name": row.name,
        "type": row.r#type,
        "enabled": row.enabled.unwrap_or(false),
        "priority": row.priority,
        "base_url": row.base_url,
        "api_key": api_key_redacted,
        "indexer_ids": row.indexer_ids.as_ref().map(|sa| sa.0.clone()),
        "categories": row.categories.as_ref().map(|sa| sa.0.clone()),
        "rate_limit": row.rate_limit,
        "connection_settings": row.connection_settings,
        "health": health,
        "rate_limit_stats": rate_limit_stats_zero(),
        "consecutive_failures": consecutive_failures,
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
