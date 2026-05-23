//! `/api/v1/indexers/*` — indexer config + health.
//!
//! Port of `MydiaWeb.Api.IndexerController` from
//! `lib/mydia_web/controllers/api/indexer_controller.ex`. The Phoenix
//! controller reads `Mydia.Settings.list_indexer_configs/0` and the
//! `Mydia.Downloads.IndexerHealth` cache; the corresponding Rust
//! surface is in `mydia_rs_indexers`, but the REST-facing JSON
//! serialization ports as a U33 follow-up.

use axum::{
    response::Response,
    routing::{get, post},
    Router,
};

use crate::api::v1::not_implemented;

pub fn router() -> Router {
    Router::new()
        .route("/api/v1/indexers", get(index))
        .route("/api/v1/indexers/refresh", post(refresh))
        .route("/api/v1/indexers/{id}", get(show))
        .route("/api/v1/indexers/{id}/test", post(test))
        .route("/api/v1/indexers/{id}/reset-failures", post(reset_failures))
}

async fn index() -> Response {
    not_implemented("U33.indexer.index")
}

async fn show() -> Response {
    not_implemented("U33.indexer.show")
}

async fn test() -> Response {
    not_implemented("U33.indexer.test")
}

async fn refresh() -> Response {
    not_implemented("U33.indexer.refresh")
}

async fn reset_failures() -> Response {
    not_implemented("U33.indexer.reset_failures")
}
