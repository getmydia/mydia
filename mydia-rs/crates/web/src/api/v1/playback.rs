//! `/api/v1/playback/*` — resume + watch-progress tracking.
//!
//! Port of `MydiaWeb.Api.PlaybackController` from
//! `lib/mydia_web/controllers/api/playback_controller.ex`. Phoenix
//! reads/writes `Mydia.Playback.PlaybackProgress` rows keyed on
//! `(user_id, media_item_id | episode_id)`. The Rust playback context
//! lives in `mydia_rs_graphql::repos::playback` (the GraphQL
//! `playbackProgress` resolver shares its read path), but the REST
//! mutation pipeline ports as a U33 follow-up.
//!
//! The GET handlers return the "no progress yet" default so the
//! Flutter player's resume-prompt logic doesn't break when it polls
//! this endpoint against the Rust backend before any progress has
//! been recorded.

use axum::{
    extract::Path,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde_json::json;

use crate::api::v1::not_implemented;

pub fn router() -> Router {
    Router::new()
        .route("/api/v1/playback/movie/{id}", get(show_movie))
        .route("/api/v1/playback/movie/{id}", post(update_movie))
        .route("/api/v1/playback/episode/{id}", get(show_episode))
        .route("/api/v1/playback/episode/{id}", post(update_episode))
        .route("/api/v1/playback/file/{id}", get(show_file))
        .route("/api/v1/playback/file/{id}", post(update_file))
}

async fn show_movie(Path(_id): Path<String>) -> Response {
    default_progress()
}

async fn show_episode(Path(_id): Path<String>) -> Response {
    default_progress()
}

async fn show_file(Path(_id): Path<String>) -> Response {
    default_progress()
}

async fn update_movie(Path(_id): Path<String>) -> Response {
    not_implemented("U33.playback.update_movie")
}

async fn update_episode(Path(_id): Path<String>) -> Response {
    not_implemented("U33.playback.update_episode")
}

async fn update_file(Path(_id): Path<String>) -> Response {
    // Phoenix returns an empty acknowledgement for file-scoped
    // updates (adult-content path that never writes a row). Mirror
    // that so the player's HEAD requests don't see a 501 cascade.
    let body = json!({
        "position_seconds": 0,
        "duration_seconds": null,
        "completion_percentage": 0,
        "watched": false
    });
    (StatusCode::OK, Json(body)).into_response()
}

fn default_progress() -> Response {
    let body = json!({
        "position_seconds": 0,
        "duration_seconds": null,
        "completion_percentage": 0,
        "watched": false
    });
    (StatusCode::OK, Json(body)).into_response()
}
