//! `/api/v1/hls/*` — HLS session lifecycle + playlist / segment serve.
//!
//! Port of `MydiaWeb.Api.HlsController`
//! (`lib/mydia_web/controllers/api/hls_controller.ex`). The session
//! state machine lives in `mydia_rs_streaming::supervisor` /
//! `::session` and is functional today; this REST surface is the
//! external HTTP entry point.
//!
//! TODO(U33-follow-up): wire the supervisor handle into `WebState` and
//! port the `start_session` / playlist / segment handlers. Until then
//! the routes are mounted and return `501 Not Implemented`.

use axum::{
    middleware::from_fn,
    response::Response,
    routing::{delete, get, post},
    Router,
};

use crate::api::auth_layer::media_token_auth;
use crate::api::v1::not_implemented;

pub fn router() -> Router {
    Router::new()
        .route("/api/v1/hls/start", post(start_session))
        .route("/api/v1/hls/{session_id}", delete(terminate_session))
        .route("/api/v1/hls/{session_id}/index.m3u8", get(master_playlist))
        .route(
            "/api/v1/hls/{session_id}/{track_id}/index.m3u8",
            get(variant_playlist),
        )
        .route(
            "/api/v1/hls/{session_id}/{track_id}/{segment}",
            get(segment),
        )
        // The single-segment variant (root_segment) overlaps the
        // master_playlist route's shape; axum picks the more specific
        // path (with `/index.m3u8`) automatically, falling through
        // here for ffmpeg's flat segment layout.
        .route("/api/v1/hls/{session_id}/{segment}", get(root_segment))
        .layer(from_fn(media_token_auth))
}

async fn start_session() -> Response {
    not_implemented("U33.hls.start_session")
}

async fn terminate_session() -> Response {
    not_implemented("U33.hls.terminate_session")
}

async fn master_playlist() -> Response {
    not_implemented("U33.hls.master_playlist")
}

async fn variant_playlist() -> Response {
    not_implemented("U33.hls.variant_playlist")
}

async fn segment() -> Response {
    not_implemented("U33.hls.segment")
}

async fn root_segment() -> Response {
    not_implemented("U33.hls.root_segment")
}
