//! `/api/v1/download/*` — operator-initiated download pipeline.
//!
//! Port of `MydiaWeb.Api.DownloadController` from
//! `lib/mydia_web/controllers/api/download_controller.ex`. The Phoenix
//! handler orchestrates transcode-for-download — `options` runs the
//! resolution detector, `prepare` enqueues a transcode job, the
//! `job_status` + `job_file` endpoints read from `transcode_jobs` plus
//! the transcoder service.
//!
//! Architectural gap (left as 501 + TODO):
//! - The Phoenix `Mydia.Downloads.DownloadService` orchestrator is not
//!   yet ported. `mydia_rs_downloads::transcoder` covers the worker
//!   side but the "pick a resolution from the source file" + "look up
//!   an existing job by media id" entry points haven't grown a
//!   service-shaped wrapper.
//! - `options` needs `ffprobe`-driven inspection of the source file
//!   plus a quality-profile resolver to compute available outputs.
//! - `prepare` needs an idempotent job-enqueue (return existing job
//!   if one is already pending / running for the same media id +
//!   resolution combination).
//! - `job_status` + `job_file` would query the `transcode_jobs` row
//!   directly; the row layout matches the Phoenix schema so the read
//!   path is reachable today but the write path isn't.
//!
//! TODO(U33-follow-up.download): land `DownloadService` in
//! `mydia_rs_downloads` first (mirroring
//! `lib/mydia/downloads/download_service.ex`), then point the REST
//! handlers at it. Mirror the Phoenix response shapes for the
//! single-resolution + multi-resolution job paths.

use axum::{
    middleware::from_fn,
    response::Response,
    routing::{delete, get, post},
    Router,
};

use crate::api::auth_layer::api_key_auth;
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
        .layer(from_fn(api_key_auth))
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
