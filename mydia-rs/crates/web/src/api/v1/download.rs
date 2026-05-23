//! `/api/v1/download/*` — operator-initiated download pipeline.
//!
//! Port of `MydiaWeb.Api.DownloadController` from
//! `lib/mydia_web/controllers/api/download_controller.ex`. The Phoenix
//! handler orchestrates search across `Mydia.Downloads.Releases`, then
//! enqueues an apalis-equivalent oban job for the chosen release.
//! `crates/downloads` ports the underlying primitives; the REST entry
//! point is wired here but the body is scaffolded with a TODO marker
//! until the job dispatch glue lands.

use axum::{
    response::Response,
    routing::{delete, get, post},
    Router,
};

use crate::api::v1::not_implemented;

pub fn router() -> Router {
    Router::new()
        .route("/api/v1/download/{content_type}/{id}/options", get(options))
        .route(
            "/api/v1/download/{content_type}/{id}/prepare",
            post(prepare),
        )
        .route("/api/v1/download/job/{job_id}/status", get(job_status))
        .route("/api/v1/download/job/{job_id}", delete(cancel_job))
        .route("/api/v1/download/job/{job_id}/file", get(download_file))
}

async fn options() -> Response {
    not_implemented("U33.download.options")
}

async fn prepare() -> Response {
    not_implemented("U33.download.prepare")
}

async fn job_status() -> Response {
    not_implemented("U33.download.job_status")
}

async fn cancel_job() -> Response {
    not_implemented("U33.download.cancel_job")
}

async fn download_file() -> Response {
    not_implemented("U33.download.download_file")
}
