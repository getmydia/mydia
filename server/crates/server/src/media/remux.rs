//! fMP4 remux. Filled in by Task 9.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use mydia_db::media_files::MediaFileRow;

pub async fn serve(_row: &MediaFileRow) -> Response {
    StatusCode::NOT_IMPLEMENTED.into_response()
}
