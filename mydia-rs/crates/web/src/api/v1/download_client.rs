//! `/api/v1/downloads/clients/*` — download-client config + health.
//!
//! Port of `MydiaWeb.Api.DownloadClientController` from
//! `lib/mydia_web/controllers/api/download_client_controller.ex`. The
//! Phoenix controller reads `Mydia.Settings.list_download_client_configs/0`
//! and `Mydia.Downloads.ClientHealth`; the corresponding Rust surface
//! lives in `mydia_rs_downloads::adapter` and `::registry`, but the
//! REST-facing JSON serialization ports as a U33 follow-up.
//!
//! Routes are mounted so the Flutter player and the operator UI see
//! the Phoenix URL shape; handlers return `501 Not Implemented` with a
//! TODO marker.

use axum::{
    middleware::from_fn,
    response::Response,
    routing::{get, post},
    Router,
};

use crate::api::auth_layer::api_key_auth;
use crate::api::v1::not_implemented;

pub fn router() -> Router {
    Router::new()
        .route("/api/v1/downloads/clients", get(index))
        .route("/api/v1/downloads/clients/refresh", post(refresh))
        .route("/api/v1/downloads/clients/{id}", get(show))
        .route("/api/v1/downloads/clients/{id}/test", post(test))
        .layer(from_fn(api_key_auth))
}

async fn index() -> Response {
    not_implemented("U33.download_client.index")
}

async fn show() -> Response {
    not_implemented("U33.download_client.show")
}

async fn test() -> Response {
    not_implemented("U33.download_client.test")
}

async fn refresh() -> Response {
    not_implemented("U33.download_client.refresh")
}
