//! `/api/v1/*` REST surface. Mirrors `MydiaWeb.Api.*` from
//! `lib/mydia_web/controllers/api/`.
//!
//! Each submodule exports a `router()` that contributes its handlers
//! to the merged router returned by [`router`]. Handlers that depend
//! on context modules not yet ported (`Mydia.Settings`,
//! `Mydia.Playback`, `Mydia.Downloads.*`) return `501 Not Implemented`
//! with a structured JSON error and a TODO marker; the route is still
//! mounted so the Flutter player and the operator UI see the same URL
//! shape Phoenix exposes.

pub mod config;
pub mod download;
pub mod download_client;
pub mod hls;
pub mod indexer;
pub mod media;
pub mod playback;
pub mod stream;
pub mod thumbnail;

use axum::Router;

/// Merge every `/api/v1/*` submodule into a single Router.
pub fn router() -> Router {
    Router::new()
        .merge(config::router())
        .merge(download::router())
        .merge(download_client::router())
        .merge(hls::router())
        .merge(indexer::router())
        .merge(media::router())
        .merge(playback::router())
        .merge(stream::router())
        .merge(thumbnail::router())
}

/// Build a JSON `{ "error": "..." }` response with the supplied status.
/// Shared by every controller in this tree so the wire shape stays
/// consistent with Phoenix's `json(conn, %{error: "..."})` style.
pub(crate) fn json_error(
    status: axum::http::StatusCode,
    message: impl Into<String>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let body = serde_json::json!({ "error": message.into() });
    (status, axum::Json(body)).into_response()
}

/// `501 Not Implemented` with a `TODO` marker. Used by the controllers
/// whose Phoenix equivalents call deep into context modules that
/// haven't been ported to Rust yet. The route is still mounted so the
/// surface matches Phoenix's URL shape and downstream clients fail
/// loudly rather than getting a `404 Not Found`.
pub(crate) fn not_implemented(todo_id: &str) -> axum::response::Response {
    use axum::http::StatusCode;
    use axum::response::IntoResponse;
    let body = serde_json::json!({
        "error": "Not implemented in mydia-rs yet",
        "todo": todo_id,
        "hint": "This endpoint is mounted but its handler ports as a U33 follow-up slice.",
    });
    (StatusCode::NOT_IMPLEMENTED, axum::Json(body)).into_response()
}
