//! Byte serving for direct play and remux.

use axum::body::Body;
use axum::extract::{Path, Query, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use serde::Deserialize;
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;

use crate::media::auth::authorize;
use crate::media::range::{mime_for, parse, Range};
use crate::AppState;

#[derive(Debug, Deserialize)]
pub struct StreamQuery {
    pub strategy: Option<String>,
    pub token: Option<String>,
}

pub async fn stream_file(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<StreamQuery>,
    headers: HeaderMap,
) -> Response {
    serve(state, "file", &id, query, headers).await
}

pub async fn stream_movie(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<StreamQuery>,
    headers: HeaderMap,
) -> Response {
    serve(state, "movie", &id, query, headers).await
}

pub async fn stream_episode(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<StreamQuery>,
    headers: HeaderMap,
) -> Response {
    serve(state, "episode", &id, query, headers).await
}

async fn serve(
    state: AppState,
    content_type: &str,
    id: &str,
    query: StreamQuery,
    headers: HeaderMap,
) -> Response {
    if let Err(status) = authorize(&state.issuer, &headers, query.token.as_deref()) {
        return status.into_response();
    }

    let Ok(row) = mydia_api::streaming::resolve_file(&state.db, content_type, id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };

    let Ok(metadata) = tokio::fs::metadata(&row.path).await else {
        tracing::warn!(path = %row.path, "media file is missing from disk");
        return StatusCode::NOT_FOUND.into_response();
    };

    // stream_controller.ex:234-257 routes on the client-selected strategy.
    // Only REMUX changes what the bytes are; every other value, including an
    // unrecognized one, serves the file as it sits on disk.
    if query.strategy.as_deref() == Some("REMUX") {
        return crate::media::remux::serve(&row).await;
    }

    serve_range(&row.path, metadata.len(), &headers).await
}

async fn serve_range(path: &str, size: u64, headers: &HeaderMap) -> Response {
    let range_header = headers.get(header::RANGE).and_then(|v| v.to_str().ok());
    let mime = mime_for(path);

    match parse(range_header, size) {
        Range::Satisfiable { start, end } => {
            let length = end - start + 1;

            let Ok(mut file) = tokio::fs::File::open(path).await else {
                return StatusCode::NOT_FOUND.into_response();
            };

            if file.seek(std::io::SeekFrom::Start(start)).await.is_err() {
                return StatusCode::INTERNAL_SERVER_ERROR.into_response();
            }

            let body = Body::from_stream(ReaderStream::new(file.take(length)));

            (
                StatusCode::PARTIAL_CONTENT,
                [
                    (header::ACCEPT_RANGES, "bytes".to_string()),
                    (header::CONTENT_TYPE, mime.to_string()),
                    (header::CONTENT_RANGE, format!("bytes {start}-{end}/{size}")),
                    (header::CONTENT_LENGTH, length.to_string()),
                    ("x-streaming-mode".parse().unwrap(), "direct".to_string()),
                ],
                body,
            )
                .into_response()
        }

        Range::Absent => {
            let Ok(file) = tokio::fs::File::open(path).await else {
                return StatusCode::NOT_FOUND.into_response();
            };

            (
                StatusCode::OK,
                [
                    (header::ACCEPT_RANGES, "bytes".to_string()),
                    (header::CONTENT_TYPE, mime.to_string()),
                    (header::CONTENT_LENGTH, size.to_string()),
                    ("x-streaming-mode".parse().unwrap(), "direct".to_string()),
                ],
                Body::from_stream(ReaderStream::new(file)),
            )
                .into_response()
        }

        Range::Unsatisfiable => (
            StatusCode::RANGE_NOT_SATISFIABLE,
            [(header::CONTENT_RANGE, format!("bytes */{size}"))],
        )
            .into_response(),
    }
}
