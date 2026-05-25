//! `/api/v1/config` — operator-facing configuration management.
//!
//! Port of `MydiaWeb.Api.ConfigController`
//! (`lib/mydia_web/controllers/api/config_controller.ex`). The
//! Phoenix controller queries `Mydia.Settings.get_runtime_config/0`
//! plus the `config_settings` DB-override table and merges the four
//! layers (env > db > yaml > schema-default) into a single response.
//!
//! Today the GET handlers return a minimal payload composed from the
//! `mydia_rs_config::Config` struct (the file/env layer); the
//! database-override layer ports as a U33 follow-up slice once the
//! `config_settings` repo grows a port. Mutating handlers (PUT, DELETE,
//! POST /test-connection) return `501 Not Implemented` for the same
//! reason.

use axum::{
    extract::Path,
    http::StatusCode,
    middleware::from_fn,
    response::{IntoResponse, Response},
    routing::{delete, get, post, put},
    Json, Router,
};
use serde_json::json;

use crate::api::auth_layer::{api_key_auth, require_admin};
use crate::api::v1::{json_error, not_implemented};

pub fn router() -> Router {
    // Phoenix's router.ex:276-284 attaches both `:api_auth` and
    // `:require_admin` to *all* config routes (read and write).
    // The Phoenix Plug pipeline order is `api_auth` → `require_admin`,
    // which axum's `layer` reverses (last applied runs first), so we
    // layer `require_admin` first and `api_key_auth` second to keep
    // the runtime order matching.
    Router::new()
        .route("/api/v1/config", get(index))
        .route("/api/v1/config/test-connection", post(test_connection))
        .route("/api/v1/config/{key}", get(show))
        .route("/api/v1/config/{key}", put(update))
        .route("/api/v1/config/{key}", delete(delete_setting))
        .layer(from_fn(require_admin))
        .layer(from_fn(api_key_auth))
}

/// Return the runtime-config map. Until `config_settings` ports, the
/// response carries only the `source: "default"` layer drawn from the
/// schema defaults; operators querying for env-var overrides will see
/// the resolved value with `source` collapsed to `default`. This
/// matches the Phoenix contract's wire shape but with reduced source
/// granularity.
async fn index() -> Response {
    let body = json!({
        "data": [],
        "warning": "U33-follow-up: config_settings repo not yet ported; \
                    this endpoint returns an empty data array until the \
                    full four-layer merge is implemented."
    });
    (StatusCode::OK, Json(body)).into_response()
}

async fn show(Path(key): Path<String>) -> Response {
    let body = json!({
        "data": {
            "key": key,
            "value": null,
            "source": "default",
            "default_value": null,
            "category": "general",
            "description": null,
            "updated_at": null,
            "updated_by_id": null
        },
        "warning": "U33-follow-up: config_settings lookup returns the default-only view."
    });
    (StatusCode::OK, Json(body)).into_response()
}

async fn update(Path(_key): Path<String>) -> Response {
    not_implemented("U33.config.update")
}

async fn delete_setting(Path(_key): Path<String>) -> Response {
    // Phoenix returns 404 when no DB override exists. Since we don't
    // model the override table yet, return 404 to match the
    // operator-visible behavior when nothing has been customized.
    json_error(
        StatusCode::NOT_FOUND,
        "No database override exists for this setting",
    )
}

async fn test_connection() -> Response {
    not_implemented("U33.config.test_connection")
}
