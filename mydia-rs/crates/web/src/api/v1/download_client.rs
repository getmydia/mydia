//! `/api/v1/downloads/clients/*` — download-client config + health.
//!
//! Port of `MydiaWeb.Api.DownloadClientController` from
//! `lib/mydia_web/controllers/api/download_client_controller.ex`.
//! `index` and `show` query the `download_client_configs` table and
//! return the Phoenix-shaped JSON projection.
//!
//! `test` forces a fresh probe through [`crate::download_probes::ProbeCache`]
//! by invalidating the entry for the target id before dispatching.
//! `refresh` calls [`crate::download_probes::ProbeCache::invalidate_all`]
//! so the next operator probe across every client lands fresh. Both
//! mirror the Phoenix `Mydia.Downloads.ClientHealth.check_health/2`
//! semantics (forced refresh on demand, cache-backed otherwise) and
//! the Phoenix REST response shape (`{"data": health}` for `test`,
//! `{"message": "..."}` with a 202 for `refresh`).

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
use crate::api::v1::json_error;
use crate::download_probes::{ProbeEntry, DEFAULT_TTL};
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
            let clients: Vec<serde_json::Value> = rows
                .iter()
                .map(|row| {
                    let health = state
                        .download_probes
                        .cached(&row.id)
                        .as_ref()
                        .map_or_else(health_unknown, serialize_health);
                    serialize_summary(row, &health)
                })
                .collect();
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
            let health = state
                .download_probes
                .cached(&row.id)
                .as_ref()
                .map_or_else(health_unknown, serialize_health);
            let body = json!({ "data": serialize_detail(&row, &health) });
            (StatusCode::OK, Json(body)).into_response()
        }
        Ok(None) => json_error(StatusCode::NOT_FOUND, "Download client not found"),
        Err(err) => {
            tracing::error!(error = ?err, id, "download_client.show db error");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error")
        }
    }
}

/// `POST /api/v1/downloads/clients/:id/test` — forced probe.
///
/// Mirrors Phoenix's `Mydia.Downloads.ClientHealth.check_health(id,
/// force: true)`: invalidate any cached entry first, then dispatch
/// a fresh probe through [`ProbeCache::probe`]. The cache picks the
/// right adapter from its [`ClientRegistry`] by `kind`.
///
/// Response shapes mirror Phoenix:
/// - `200 OK { "data": health }` — probe completed (`status` is
///   `healthy` / `unhealthy` based on the adapter's verdict).
/// - `404 Not Found { "error": "..." }` — no row with that id.
/// - `500 Internal Server Error { "error": "..." }` — DB read failed.
async fn test(Extension(state): Extension<WebState>, Path(id): Path<String>) -> Response {
    match lookup_probe_target(&state, &id).await {
        Ok(Some(target)) => {
            // Phoenix forces a fresh probe; mirror by dropping the
            // cached entry before calling `probe`. The cache will
            // re-populate from the run.
            state.download_probes.invalidate(&id);
            let entry = probe_target(&state, &id, &target).await;
            (
                StatusCode::OK,
                Json(json!({ "data": serialize_health(&entry) })),
            )
                .into_response()
        }
        Ok(None) => json_error(StatusCode::NOT_FOUND, "Download client not found"),
        Err(err) => {
            tracing::error!(error = ?err, id, "download_client.test db error");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error")
        }
    }
}

/// `POST /api/v1/downloads/clients/refresh` — bulk cache flush.
///
/// Phoenix returns `202 Accepted` with a `{"message": "..."}` body
/// because its `ClientHealth.refresh_all_clients/0` casts to the
/// `GenServer` and fans out background tasks. Our cache invalidation
/// is synchronous (the next probe will issue a fresh network call)
/// but we preserve the wire shape so clients written against the
/// Phoenix backend don't notice the difference.
async fn refresh(Extension(state): Extension<WebState>) -> Response {
    state.download_probes.invalidate_all();
    (
        StatusCode::ACCEPTED,
        Json(json!({ "message": "Health check refresh initiated" })),
    )
        .into_response()
}

/// Tuple of fields needed to dispatch a probe: `kind`, `url`,
/// `username`, `password`. Pulled separately from the summary /
/// detail rows because the REST surface never serializes the password
/// field — it lives only in the probe path.
struct ProbeTarget {
    kind: String,
    url: String,
    username: Option<String>,
    password: Option<String>,
}

async fn lookup_probe_target(
    state: &WebState,
    id: &str,
) -> Result<Option<ProbeTarget>, sqlx::Error> {
    use mydia_rs_db::Db;

    type Row = (String, Option<String>, Option<String>, Option<String>);
    let row: Option<Row> = match &state.db {
        Db::Sqlite(pool) => {
            sqlx::query_as(
                "SELECT type, host, username, password FROM download_client_configs \
             WHERE id = ? LIMIT 1",
            )
            .bind(id)
            .fetch_optional(pool)
            .await?
        }
        Db::Postgres(pool) => {
            sqlx::query_as(
                "SELECT type, host, username, password FROM download_client_configs \
             WHERE id = $1 LIMIT 1",
            )
            .bind(id)
            .fetch_optional(pool)
            .await?
        }
    };

    Ok(row.map(|(kind, host, username, password)| ProbeTarget {
        kind,
        // Phoenix stores `host` + `port` + `use_ssl` separately and
        // builds the URL in the adapter; the REST `test` endpoint only
        // needs the host string to feed `config_from_url`. We compose
        // a placeholder when the host is empty so the probe surfaces a
        // human-readable error instead of an SQL surprise.
        url: host.unwrap_or_default(),
        username,
        password,
    }))
}

async fn probe_target(state: &WebState, id: &str, target: &ProbeTarget) -> ProbeEntry {
    use crate::download_probes::config_from_url;

    // For blackhole + similar "drop into a folder" adapters the host
    // field is a filesystem path. The download probe cache short-
    // circuits the same way the admin server fn does for parity.
    if target.url.starts_with('/') {
        return ProbeEntry {
            ok: true,
            message: format!(
                "{}: watch folder configured at {:?}",
                target.kind, target.url
            ),
            ts: std::time::Instant::now(),
        };
    }

    // We accept bare hostnames too; default to `http://host` when no
    // scheme is present so `config_from_url` always sees a URL.
    let url = if target.url.contains("://") {
        target.url.clone()
    } else {
        format!("http://{}", target.url)
    };

    match config_from_url(&url, target.username.as_deref(), target.password.as_deref()) {
        Ok(config) => state.download_probes.probe(id, &target.kind, config).await,
        Err(err) => ProbeEntry {
            ok: false,
            message: format!("invalid url: {err}"),
            ts: std::time::Instant::now(),
        },
    }
}

/// Serialize a [`ProbeEntry`] into Phoenix's `health_result` shape
/// (`status`, `checked_at`, `details`, `error`). The exact field
/// shape matches Phoenix so existing clients render unmodified.
fn serialize_health(entry: &ProbeEntry) -> serde_json::Value {
    // The cache stores `Instant`, which has no calendar mapping; we
    // back-derive a wall-clock timestamp from "now minus elapsed".
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

fn serialize_summary(row: &DownloadClientRow, health: &serde_json::Value) -> serde_json::Value {
    json!({
        "id": row.id,
        "name": row.name,
        "type": row.r#type,
        "enabled": row.enabled.unwrap_or(false),
        "priority": row.priority,
        "host": row.host,
        "port": row.port,
        "use_ssl": row.use_ssl.unwrap_or(false),
        "health": health,
    })
}

fn serialize_detail(row: &DownloadClientRow, health: &serde_json::Value) -> serde_json::Value {
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
        "health": health,
    })
}

/// Wire shape Phoenix returns for an as-yet-unprobed client. The
/// operator UI renders this as a neutral "not yet tested" badge. Once
/// the cache has an entry (after the first `test` call), [`serialize_health`]
/// fills in the full Phoenix shape.
fn health_unknown() -> serde_json::Value {
    json!({ "status": "unknown" })
}
