//! `/api/v1/download/*` — player-driven transcode download surface.
//!
//! Port of `MydiaWeb.Api.DownloadController` from
//! `lib/mydia_web/controllers/api/download_controller.ex`. Every route
//! here funnels into [`mydia_rs_downloads::DownloadService`], the Rust
//! port of `Mydia.Downloads.DownloadService`.
//!
//! ## Routes
//!
//! - `GET /api/v1/download/:content_type/:id/options` — list available
//!   quality options for a media file. `content_type` is `"movie"` or
//!   `"episode"`; `id` is the parent's id.
//! - `POST /api/v1/download/:content_type/:id/prepare` — idempotent
//!   enqueue. Body: `{"resolution": "720p"}` (defaults to `"720p"` when
//!   absent). Returns the live job row.
//! - `GET /api/v1/download/job/:job_id/status` — quick status read.
//! - `DELETE /api/v1/download/job/:job_id` — cancel + delete.
//! - `GET /api/v1/download/job/:job_id/file` — serve the transcoded
//!   `.mp4` (or the source file for `"original"`) with `Range:`
//!   support. Progressive-download capable: while the transcoder is
//!   still writing, the handler streams what's already on disk and
//!   sets `X-Transcode-Status: in-progress`.
//!
//! ## Auth
//!
//! Wrapped in [`crate::api::auth_layer::api_key_auth`] per Phoenix's
//! `:api_auth` pipeline (router.ex:213). The session-cookie path is
//! honored too because some operators reach the endpoints from the
//! admin UI; that's the auth layer's job, not ours.

use std::path::Path;

use axum::{
    body::Body,
    extract::{Path as AxumPath, Query},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    middleware::from_fn,
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Extension, Json, Router,
};
use mydia_rs_downloads::{DownloadService, Job, ServiceError};
use serde::Deserialize;
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;

use crate::api::auth_layer::api_key_auth;
use crate::api::range_helper::{
    calculate_range, format_content_range, get_mime_type, parse_range_header, RangeOutcome,
};
use crate::api::v1::json_error;
use crate::WebState;

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

#[derive(Debug, Deserialize)]
struct PrepareBody {
    #[serde(default)]
    resolution: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
struct PrepareQuery {
    #[serde(default)]
    resolution: Option<String>,
}

async fn options(
    Extension(state): Extension<WebState>,
    AxumPath((content_type, id)): AxumPath<(String, String)>,
) -> Response {
    let Some(service) = state.download_service.as_ref() else {
        return service_unconfigured();
    };
    match service.get_options(&content_type, &id).await {
        Ok(options) => {
            let body = serde_json::json!({ "options": options });
            (StatusCode::OK, Json(body)).into_response()
        }
        Err(err) => render_service_error(&err, "download.options"),
    }
}

async fn prepare(
    Extension(state): Extension<WebState>,
    AxumPath((content_type, id)): AxumPath<(String, String)>,
    Query(query): Query<PrepareQuery>,
    body: Option<Json<PrepareBody>>,
) -> Response {
    let Some(service) = state.download_service.as_ref() else {
        return service_unconfigured();
    };

    // Phoenix accepts the resolution either as a JSON body field or as
    // a query string. The body wins when both are present; both default
    // to "720p" when missing — matches the Phoenix
    // `params["resolution"] || "720p"` shape.
    let resolution = body
        .and_then(|Json(b)| b.resolution)
        .or(query.resolution)
        .unwrap_or_else(|| "720p".to_owned());

    match service.prepare(&content_type, &id, &resolution).await {
        Ok(info) => {
            let body = serde_json::json!({
                "job_id": info.job_id,
                "status": info.status,
                "progress": info.progress,
            });
            (StatusCode::OK, Json(body)).into_response()
        }
        Err(err) => render_service_error(&err, "download.prepare"),
    }
}

async fn job_status(
    Extension(state): Extension<WebState>,
    AxumPath(job_id): AxumPath<String>,
) -> Response {
    let Some(service) = state.download_service.as_ref() else {
        return service_unconfigured();
    };
    match service.get_job_status(&job_id).await {
        Ok(info) => {
            let body = serde_json::json!({
                "job_id": info.job_id,
                "status": info.status,
                "progress": info.progress,
                "error": info.error,
                "file_size": info.file_size,
            });
            (StatusCode::OK, Json(body)).into_response()
        }
        Err(ServiceError::JobNotFound) => json_error(StatusCode::NOT_FOUND, "Job not found"),
        Err(err) => render_service_error(&err, "download.job_status"),
    }
}

async fn cancel_job(
    Extension(state): Extension<WebState>,
    AxumPath(job_id): AxumPath<String>,
) -> Response {
    let Some(service) = state.download_service.as_ref() else {
        return service_unconfigured();
    };
    match service.cancel_job(&job_id).await {
        Ok(()) => {
            let body = serde_json::json!({ "status": "cancelled" });
            (StatusCode::OK, Json(body)).into_response()
        }
        Err(ServiceError::JobNotFound) => json_error(StatusCode::NOT_FOUND, "Job not found"),
        Err(err) => render_service_error(&err, "download.cancel_job"),
    }
}

async fn download_file(
    Extension(state): Extension<WebState>,
    AxumPath(job_id): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    let Some(service) = state.download_service.as_ref() else {
        return service_unconfigured();
    };

    let job = match service.get_job(&job_id).await {
        Ok(job) => job,
        Err(ServiceError::JobNotFound) => {
            return json_error(StatusCode::NOT_FOUND, "Job not found");
        }
        Err(err) => return render_service_error(&err, "download.download_file"),
    };

    dispatch_download_file(service, &job, &headers).await
}

/// Inner branch: pattern-match on `(status, output_path)` to pick the
/// response shape. Mirrors the Phoenix controller's `case` block.
async fn dispatch_download_file(
    service: &DownloadService,
    job: &Job,
    headers: &HeaderMap,
) -> Response {
    match job.status.as_str() {
        "pending" => (
            StatusCode::ACCEPTED,
            Json(serde_json::json!({
                "error": "Transcode not started yet",
                "status": "pending",
            })),
        )
            .into_response(),
        "transcoding" => match job.output_path.as_deref() {
            Some(path) if !path.is_empty() => {
                serve_file_with_range(service, job, Path::new(path), headers, true).await
            }
            _ => (
                StatusCode::ACCEPTED,
                Json(serde_json::json!({
                    "error": "Transcode in progress, file not yet available",
                    "status": "transcoding",
                })),
            )
                .into_response(),
        },
        "ready" => match job.output_path.as_deref() {
            Some(path) if !path.is_empty() => {
                serve_file_with_range(service, job, Path::new(path), headers, false).await
            }
            _ => json_error(StatusCode::INTERNAL_SERVER_ERROR, "File not available"),
        },
        "failed" => {
            let detail = job.error.as_deref().unwrap_or("Unknown error");
            json_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Transcode failed: {detail}"),
            )
        }
        _ => json_error(StatusCode::INTERNAL_SERVER_ERROR, "File not available"),
    }
}

/// Serve the transcoded output (or the source file for `"original"`)
/// with `Range:` support. Identical layout to the stream handler but
/// taught to bump `last_accessed_at` on the row so the LRU worker has
/// fresh signal.
async fn serve_file_with_range(
    service: &DownloadService,
    job: &Job,
    path: &Path,
    headers: &HeaderMap,
    transcoding: bool,
) -> Response {
    let Ok(metadata) = tokio::fs::metadata(path).await else {
        return json_error(StatusCode::NOT_FOUND, "File not found");
    };
    if !metadata.is_file() {
        return json_error(StatusCode::NOT_FOUND, "File not found");
    }

    // Best-effort bump. Logging only if it fails — we still want to
    // serve the file even if the DB write hiccups.
    if let Err(err) = service.touch_last_accessed(&job.id).await {
        tracing::warn!(error = ?err, job_id = %job.id, "touch_last_accessed failed");
    }

    let file_size = metadata.len();
    let mime = get_mime_type(path);
    let range_header = headers
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    if range_header.is_empty() {
        return full_body_response(path, file_size, mime, transcoding).await;
    }
    match parse_range_header(range_header, file_size) {
        RangeOutcome::Range { start, end } => {
            partial_body_response(path, start, end, file_size, mime, transcoding).await
        }
        RangeOutcome::Invalid => {
            let mut response =
                json_error(StatusCode::RANGE_NOT_SATISFIABLE, "Invalid range request");
            response.headers_mut().insert(
                header::CONTENT_RANGE,
                HeaderValue::from_str(&format!("bytes */{file_size}"))
                    .expect("content-range value is ASCII"),
            );
            response
        }
    }
}

async fn full_body_response(
    path: &Path,
    file_size: u64,
    mime: &str,
    transcoding: bool,
) -> Response {
    let Ok(file) = tokio::fs::File::open(path).await else {
        return json_error(StatusCode::NOT_FOUND, "File not found");
    };
    let stream = ReaderStream::new(file);
    let body = Body::from_stream(stream);
    let mut response = Response::new(body);
    *response.status_mut() = StatusCode::OK;
    let h = response.headers_mut();
    h.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    h.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(mime).unwrap_or(HeaderValue::from_static("application/octet-stream")),
    );
    h.insert(
        header::CONTENT_LENGTH,
        HeaderValue::from_str(&file_size.to_string()).expect("content-length is ASCII"),
    );
    add_transcoding_header(h, transcoding);
    response
}

async fn partial_body_response(
    path: &Path,
    start: u64,
    end: u64,
    file_size: u64,
    mime: &str,
    transcoding: bool,
) -> Response {
    let (offset, length) = calculate_range(start, end);
    let content_range = format_content_range(start, end, file_size);

    let Ok(mut file) = tokio::fs::File::open(path).await else {
        return json_error(StatusCode::NOT_FOUND, "File not found");
    };
    if let Err(err) = file.seek(std::io::SeekFrom::Start(offset)).await {
        tracing::error!(error = ?err, ?path, "seek failed");
        return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Seek failed");
    }
    let bounded = file.take(length);
    let stream = ReaderStream::new(bounded);
    let body = Body::from_stream(stream);
    let mut response = Response::new(body);
    *response.status_mut() = StatusCode::PARTIAL_CONTENT;
    let h = response.headers_mut();
    h.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    h.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(mime).unwrap_or(HeaderValue::from_static("application/octet-stream")),
    );
    h.insert(
        header::CONTENT_RANGE,
        HeaderValue::from_str(&content_range).expect("content-range is ASCII"),
    );
    h.insert(
        header::CONTENT_LENGTH,
        HeaderValue::from_str(&length.to_string()).expect("content-length is ASCII"),
    );
    add_transcoding_header(h, transcoding);
    response
}

fn add_transcoding_header(headers: &mut axum::http::HeaderMap, transcoding: bool) {
    if transcoding {
        headers.insert(
            "x-transcode-status",
            HeaderValue::from_static("in-progress"),
        );
    }
}

fn render_service_error(err: &ServiceError, scope: &str) -> Response {
    match err {
        ServiceError::NotFound => json_error(StatusCode::NOT_FOUND, "Media not found"),
        ServiceError::NoMediaFile => json_error(
            StatusCode::NOT_FOUND,
            "No media file available for download",
        ),
        ServiceError::InvalidResolution => json_error(
            StatusCode::BAD_REQUEST,
            "Invalid resolution. Must be one of: original, 1080p, 720p, 480p",
        ),
        ServiceError::SourceFileNotFound => {
            json_error(StatusCode::NOT_FOUND, "Source file not found")
        }
        ServiceError::JobNotFound => json_error(StatusCode::NOT_FOUND, "Job not found"),
        ServiceError::Db(e) => {
            tracing::error!(error = ?e, scope, "download service db error");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error")
        }
        ServiceError::Internal(msg) => {
            tracing::error!(scope, %msg, "download service internal error");
            json_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Failed to prepare download",
            )
        }
    }
}

fn service_unconfigured() -> Response {
    tracing::error!(
        "download: DownloadService missing from WebState; boot path forgot to attach it"
    );
    json_error(
        StatusCode::INTERNAL_SERVER_ERROR,
        "Download subsystem not configured",
    )
}
