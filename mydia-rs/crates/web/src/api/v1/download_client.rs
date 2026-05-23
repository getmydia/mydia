//! `/api/v1/downloads/clients/*` — download-client config + health.
//!
//! Port of `MydiaWeb.Api.DownloadClientController` from
//! `lib/mydia_web/controllers/api/download_client_controller.ex`.
//! `index` and `show` query the `download_client_configs` table and
//! return the Phoenix-shaped JSON projection. The `health` field is
//! always `{ "status": "unknown" }` until the per-client probe cache
//! ports from `Mydia.Downloads.ClientHealth`; the field shape matches
//! Phoenix so the operator UI doesn't break when callers swap
//! backends.
//!
//! `test` and `refresh` remain 501 — they require the same runtime
//! probe cache plus a one-shot probe entry point on the adapter
//! trait, neither of which exists yet on the Rust side. TODOs in
//! place so the trail stays visible.

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
        .route("/api/v1/downloads/clients", get(index))
        .route("/api/v1/downloads/clients/refresh", post(refresh))
        .route("/api/v1/downloads/clients/{id}", get(show))
        .route("/api/v1/downloads/clients/{id}/test", post(test))
        .layer(from_fn(api_key_auth))
}

#[derive(sqlx::FromRow)]
struct DownloadClientRow {
    id: String,
    name: Option<String>,
    r#type: Option<String>,
    enabled: Option<bool>,
    priority: Option<i64>,
    host: Option<String>,
    port: Option<i64>,
    use_ssl: Option<bool>,
    url_base: Option<String>,
    category: Option<String>,
    download_directory: Option<String>,
}

async fn index(Extension(state): Extension<WebState>) -> Response {
    match list_clients(&state).await {
        Ok(rows) => {
            let clients: Vec<serde_json::Value> = rows.iter().map(serialize_summary).collect();
            let body = json!({ "data": clients });
            (StatusCode::OK, Json(body)).into_response()
        }
        Err(err) => {
            tracing::error!(error = ?err, "download_client.index db error");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error")
        }
    }
}

async fn show(Extension(state): Extension<WebState>, Path(id): Path<String>) -> Response {
    match lookup_client(&state, &id).await {
        Ok(Some(row)) => {
            let body = json!({ "data": serialize_detail(&row) });
            (StatusCode::OK, Json(body)).into_response()
        }
        Ok(None) => json_error(StatusCode::NOT_FOUND, "Download client not found"),
        Err(err) => {
            tracing::error!(error = ?err, id, "download_client.show db error");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error")
        }
    }
}

async fn test(Path(_id): Path<String>) -> Response {
    // The Phoenix endpoint forces a fresh probe via
    // `Mydia.Downloads.ClientHealth.check_health(id, force: true)`.
    // The Rust adapter trait in `crates/downloads/src/adapter.rs`
    // exposes per-protocol probes but not a uniform "is_reachable"
    // shape the REST endpoint can call; landing that is its own
    // commit on the backing crate.
    not_implemented("U33.download_client.test")
}

async fn refresh() -> Response {
    not_implemented("U33.download_client.refresh")
}

async fn list_clients(state: &WebState) -> Result<Vec<DownloadClientRow>, sqlx::Error> {
    use mydia_rs_db::Db;

    let sql = "
        SELECT id, name, type, enabled, priority, host, port, use_ssl, url_base, \
               category, download_directory
        FROM download_client_configs
        ORDER BY priority ASC, name ASC
    ";

    match &state.db {
        Db::Sqlite(pool) => {
            sqlx::query_as::<_, DownloadClientRow>(sql)
                .fetch_all(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, DownloadClientRow>(sql)
                .fetch_all(pool)
                .await
        }
    }
}

async fn lookup_client(
    state: &WebState,
    id: &str,
) -> Result<Option<DownloadClientRow>, sqlx::Error> {
    use mydia_rs_db::Db;

    let sql = "
        SELECT id, name, type, enabled, priority, host, port, use_ssl, url_base, \
               category, download_directory
        FROM download_client_configs
        WHERE id = $1
        LIMIT 1
    ";

    match &state.db {
        Db::Sqlite(pool) => {
            let sql_sqlite = sql.replace("$1", "?");
            sqlx::query_as::<_, DownloadClientRow>(&sql_sqlite)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, DownloadClientRow>(sql)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
    }
}

fn serialize_summary(row: &DownloadClientRow) -> serde_json::Value {
    json!({
        "id": row.id,
        "name": row.name,
        "type": row.r#type,
        "enabled": row.enabled.unwrap_or(false),
        "priority": row.priority,
        "host": row.host,
        "port": row.port,
        "use_ssl": row.use_ssl.unwrap_or(false),
        "health": health_unknown(),
    })
}

fn serialize_detail(row: &DownloadClientRow) -> serde_json::Value {
    json!({
        "id": row.id,
        "name": row.name,
        "type": row.r#type,
        "enabled": row.enabled.unwrap_or(false),
        "priority": row.priority,
        "host": row.host,
        "port": row.port,
        "use_ssl": row.use_ssl.unwrap_or(false),
        "url_base": row.url_base,
        "category": row.category,
        "download_directory": row.download_directory,
        "health": health_unknown(),
    })
}

/// Placeholder health payload until the per-client probe cache ports.
/// Matches the wire shape Phoenix returns for an as-yet-unprobed
/// client.
fn health_unknown() -> serde_json::Value {
    json!({ "status": "unknown" })
}
