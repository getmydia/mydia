//! `/api/player/v1/subtitles/*` — subtitle track listing + extraction.
//!
//! Port of `MydiaWeb.Api.Player.V1.SubtitleController` from
//! `lib/mydia_web/controllers/api/player/v1/subtitle_controller.ex`.
//! The Phoenix controller leans on `Mydia.Subtitles.Extractor` to pull
//! tracks out of MKVs via `ffmpeg`; the Rust port lives in
//! `crates/subtitles`, but the wiring between the extractor and this
//! HTTP entry point ports as a U33 follow-up.
//!
//! The routes are mounted with the Phoenix URL shape so the Flutter
//! player's existing URLs resolve.

use axum::{response::Response, routing::get, Router};

use crate::api::v1::not_implemented;

pub fn router() -> Router {
    Router::new()
        .route("/api/player/v1/subtitles/{type}/{id}", get(index))
        .route("/api/player/v1/subtitles/{type}/{id}/{track}", get(show))
}

async fn index() -> Response {
    not_implemented("U33.player.subtitles.index")
}

async fn show() -> Response {
    not_implemented("U33.player.subtitles.show")
}
