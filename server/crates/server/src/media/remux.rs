//! The REMUX byte path.

use axum::body::Body;
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use mydia_db::media_files::MediaFileRow;

pub async fn serve(row: &MediaFileRow) -> Response {
    match mydia_streaming::remux::start(&row.path, row.duration_seconds) {
        Ok(stream) => (
            StatusCode::OK,
            [
                (header::CONTENT_TYPE, "video/mp4"),
                ("x-streaming-mode".parse().unwrap(), "remux"),
            ],
            Body::from_stream(stream),
        )
            .into_response(),

        Err(error) => {
            // Rule 3 of the parent design: a bare "transcode failed" is the
            // least actionable bug report in this class of software.
            tracing::error!(path = %row.path, %error, "remux could not start");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}
