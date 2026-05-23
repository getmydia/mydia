//! `/api/v1/hls/*` — HLS session lifecycle + playlist / segment serve.
//!
//! Port of `MydiaWeb.Api.HlsController`
//! (`lib/mydia_web/controllers/api/hls_controller.ex`). The session
//! state machine lives in `mydia_rs_streaming::supervisor` /
//! `::session`; this REST surface is its external HTTP entry point.
//!
//! ## Routes
//!
//! - `POST /api/v1/hls/start` — start a session for a media file and
//!   return the master playlist URL.
//! - `DELETE /api/v1/hls/:session_id` — terminate a session.
//! - `GET /api/v1/hls/:session_id/index.m3u8` — master playlist.
//! - `GET /api/v1/hls/:session_id/:track_id/index.m3u8` — variant
//!   playlist (used by the Membrane backend's quality directories).
//! - `GET /api/v1/hls/:session_id/:track_id/:segment` — track segment.
//! - `GET /api/v1/hls/:session_id/:segment` — flat (ffmpeg-style)
//!   segment lookup; falls through here when the track-prefixed path
//!   does not match.
//!
//! ## Response shape
//!
//! Mirrors Phoenix's `HlsController`:
//! - `start` returns 200 with `{session_id, master_playlist_url, status}`
//! - `terminate` returns 200 with `{status, session_id}`
//! - playlists return 200 with `Content-Type: application/vnd.apple.mpegurl`
//! - segments return 200 with `Content-Type: video/mp2t` (or
//!   `video/iso.segment` / `video/mp4` for fragmented MP4) and a
//!   long-lived `Cache-Control` so the player's HTTP cache holds them.

use std::path::{Path, PathBuf};

use axum::{
    body::Body,
    extract::Path as AxumPath,
    http::{header, HeaderValue, StatusCode},
    middleware::from_fn,
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Extension, Json, Router,
};
use mydia_rs_db::Db;
use mydia_rs_models::MediaFile;
use serde::Deserialize;
use tokio_util::io::ReaderStream;
use uuid::Uuid;

use crate::api::auth_layer::{media_token_auth, AuthenticatedUser};
use crate::api::v1::json_error;
use crate::WebState;

/// Subset of `media_files` columns we need to spawn a session. Mirrors
/// the columns the `mydia_rs_streaming::Supervisor` consumes off the
/// `MediaFile` model.
const MEDIA_FILE_COLUMNS: &str =
    "id, media_item_id, episode_id, quality_profile_id, library_path_id, path, relative_path, \
     size, resolution, codec, hdr_format, audio_codec, bitrate, verified_at, analyzed_at, \
     analysis_attempts, last_analysis_error, metadata, cover_blob, sprite_blob, vtt_blob, \
     preview_blob, phash, generated_at, trashed_at, inserted_at, updated_at";

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
        // The root-segment route overlaps `:session_id/index.m3u8` and
        // `:session_id/:track_id/index.m3u8`; axum's longest-match
        // routing picks those first, falling through here for flat
        // ffmpeg-style segments laid out directly under the session
        // temp dir.
        .route("/api/v1/hls/{session_id}/{segment}", get(root_segment))
        .layer(from_fn(media_token_auth))
}

#[derive(Debug, Deserialize)]
struct StartSessionBody {
    media_file_id: String,
}

async fn start_session(
    Extension(state): Extension<WebState>,
    Extension(user): Extension<AuthenticatedUser>,
    Json(body): Json<StartSessionBody>,
) -> Response {
    let Some(supervisor) = state.streaming_supervisor.as_ref() else {
        tracing::error!("hls start_session: streaming supervisor missing from WebState");
        return json_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Streaming subsystem not configured",
        );
    };

    let user_uuid = match Uuid::parse_str(&user.user_id) {
        Ok(u) => mydia_rs_db::types::UuidText(u),
        Err(_) => {
            return json_error(StatusCode::BAD_REQUEST, "Invalid authenticated user id");
        }
    };

    let media_file = match lookup_media_file(&state.db, &body.media_file_id).await {
        Ok(Some(mf)) => mf,
        Ok(None) => {
            return json_error(StatusCode::NOT_FOUND, "Media file not found");
        }
        Err(err) => {
            tracing::error!(error = ?err, media_file_id = %body.media_file_id, "hls start db lookup failed");
            return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error");
        }
    };

    match supervisor.start_session(&media_file, user_uuid).await {
        Ok(handle) => {
            let session_id = handle.session_id;
            let url = format!("/api/v1/hls/{session_id}/index.m3u8");
            let body = serde_json::json!({
                "session_id": session_id.to_string(),
                "master_playlist_url": url,
                "status": "ready",
            });
            (StatusCode::OK, Json(body)).into_response()
        }
        Err(err) => {
            tracing::error!(error = %err, "hls start_session failed");
            json_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Failed to start HLS session",
            )
        }
    }
}

async fn terminate_session(
    Extension(state): Extension<WebState>,
    AxumPath(session_id): AxumPath<String>,
) -> Response {
    let Some(supervisor) = state.streaming_supervisor.as_ref() else {
        return json_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Streaming subsystem not configured",
        );
    };

    let Ok(uuid) = Uuid::parse_str(&session_id) else {
        // Phoenix returns 200 with `status: "not_found"` for unknown
        // sessions; we mirror that for any unparseable id too so the
        // player's teardown path is idempotent regardless of how the
        // session id was minted.
        return (
            StatusCode::OK,
            Json(serde_json::json!({
                "status": "not_found",
                "session_id": session_id,
            })),
        )
            .into_response();
    };

    if supervisor.get(uuid).is_none() {
        return (
            StatusCode::OK,
            Json(serde_json::json!({
                "status": "not_found",
                "session_id": session_id,
            })),
        )
            .into_response();
    }

    supervisor.stop_session(uuid, "operator terminate").await;
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "status": "terminated",
            "session_id": session_id,
        })),
    )
        .into_response()
}

async fn master_playlist(
    Extension(state): Extension<WebState>,
    AxumPath(session_id): AxumPath<String>,
) -> Response {
    let Some(supervisor) = state.streaming_supervisor.as_ref() else {
        return json_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Streaming subsystem not configured",
        );
    };

    let Ok(uuid) = Uuid::parse_str(&session_id) else {
        return json_error(StatusCode::NOT_FOUND, "HLS session not found");
    };

    let Some(handle) = supervisor.get(uuid) else {
        return json_error(StatusCode::NOT_FOUND, "HLS session not found");
    };

    // Wait up to 30 seconds for the session's first playlist to
    // appear on disk (mirrors Phoenix's `await_ready(pid, 30_000)`).
    if let Err(err) = handle.await_ready(std::time::Duration::from_secs(30)).await {
        tracing::warn!(error = %err, session_id, "hls await_ready failed");
        return json_error(
            StatusCode::SERVICE_UNAVAILABLE,
            "Transcoding initialization timeout, please try again",
        );
    }

    // Heartbeat the session so its idle timer resets while the player
    // is actively pulling playlists.
    let _ = handle.heartbeat().await;

    let temp_dir = handle.temp_dir.clone();
    // Two possible names depending on the runner: ffmpeg lands at
    // `index.m3u8` (the modern path) and the legacy Phoenix code wrote
    // `playlist.m3u8`. Probe both.
    let candidates = [temp_dir.join("index.m3u8"), temp_dir.join("playlist.m3u8")];

    for path in candidates {
        if path.exists() {
            return serve_playlist_file(&path).await;
        }
    }

    tracing::warn!(
        session_id,
        ?temp_dir,
        "playlist file not found after await_ready succeeded"
    );
    json_error(
        StatusCode::INTERNAL_SERVER_ERROR,
        "Playlist file unexpectedly missing",
    )
}

async fn variant_playlist(
    Extension(state): Extension<WebState>,
    AxumPath((session_id, track_id)): AxumPath<(String, String)>,
) -> Response {
    let Some(supervisor) = state.streaming_supervisor.as_ref() else {
        return json_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Streaming subsystem not configured",
        );
    };

    let Ok(uuid) = Uuid::parse_str(&session_id) else {
        return json_error(StatusCode::NOT_FOUND, "HLS session not found");
    };

    let Some(handle) = supervisor.get(uuid) else {
        return json_error(StatusCode::NOT_FOUND, "HLS session not found");
    };

    let _ = handle.heartbeat().await;

    let path = handle.temp_dir.join(&track_id).join("index.m3u8");
    if !path.exists() {
        return json_error(StatusCode::NOT_FOUND, "Variant playlist not found");
    }
    serve_playlist_file(&path).await
}

async fn segment(
    Extension(state): Extension<WebState>,
    AxumPath((session_id, track_id, segment)): AxumPath<(String, String, String)>,
) -> Response {
    let Some(supervisor) = state.streaming_supervisor.as_ref() else {
        return json_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Streaming subsystem not configured",
        );
    };
    let Ok(uuid) = Uuid::parse_str(&session_id) else {
        return json_error(StatusCode::NOT_FOUND, "HLS session not found");
    };
    let Some(handle) = supervisor.get(uuid) else {
        return json_error(StatusCode::NOT_FOUND, "HLS session not found");
    };

    let _ = handle.heartbeat().await;

    // Membrane-style: track subdirectory under the session dir.
    let track_path = handle.temp_dir.join(&track_id).join(&segment);
    // Ffmpeg flat fallback: segment directly under the session dir
    // (Phoenix's HlsController applies the same fallback).
    let flat_path = handle.temp_dir.join(&segment);

    let path = if track_path.exists() {
        track_path
    } else if flat_path.exists() {
        flat_path
    } else {
        return json_error(StatusCode::NOT_FOUND, "Segment not found");
    };

    serve_segment_file(&path, &segment).await
}

async fn root_segment(
    Extension(state): Extension<WebState>,
    AxumPath((session_id, segment)): AxumPath<(String, String)>,
) -> Response {
    let Some(supervisor) = state.streaming_supervisor.as_ref() else {
        return json_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Streaming subsystem not configured",
        );
    };
    let Ok(uuid) = Uuid::parse_str(&session_id) else {
        return json_error(StatusCode::NOT_FOUND, "HLS session not found");
    };
    let Some(handle) = supervisor.get(uuid) else {
        return json_error(StatusCode::NOT_FOUND, "HLS session not found");
    };

    let _ = handle.heartbeat().await;

    let path = handle.temp_dir.join(&segment);
    if !path.exists() {
        return json_error(StatusCode::NOT_FOUND, "Segment not found");
    }
    serve_segment_file(&path, &segment).await
}

// ---------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------

async fn serve_playlist_file(path: &Path) -> Response {
    match tokio::fs::read(path).await {
        Ok(content) => {
            let mut response = Response::new(Body::from(content));
            *response.status_mut() = StatusCode::OK;
            let headers = response.headers_mut();
            headers.insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static("application/vnd.apple.mpegurl"),
            );
            headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
            response
        }
        Err(err) => {
            tracing::error!(error = ?err, ?path, "hls playlist read failed");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Failed to read playlist")
        }
    }
}

async fn serve_segment_file(path: &Path, name: &str) -> Response {
    let Ok(file) = tokio::fs::File::open(path).await else {
        return json_error(StatusCode::NOT_FOUND, "Segment not found");
    };

    let stream = ReaderStream::new(file);
    let body = Body::from_stream(stream);

    let mut response = Response::new(body);
    *response.status_mut() = StatusCode::OK;
    let headers = response.headers_mut();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static(segment_mime_type(name)),
    );
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=31536000, immutable"),
    );
    response
}

fn segment_mime_type(name: &str) -> &'static str {
    let ext = Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_ascii_lowercase);
    match ext.as_deref() {
        Some("m4s") => "video/iso.segment",
        Some("mp4") => "video/mp4",
        Some("ts") => "video/mp2t",
        _ => "application/octet-stream",
    }
}

async fn lookup_media_file(db: &Db, id: &str) -> Result<Option<MediaFile>, sqlx::Error> {
    let sql = format!("SELECT {MEDIA_FILE_COLUMNS} FROM media_files WHERE id = $1");
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, MediaFile>(&sql)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, MediaFile>(&sql)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
    }
}

/// Reach the path joiner from tests so they don't need to duplicate
/// the segment-dir layout logic. Hidden from rustdoc.
#[doc(hidden)]
pub fn segment_path_for_tests(temp_dir: &Path, track: Option<&str>, segment: &str) -> PathBuf {
    match track {
        Some(t) => temp_dir.join(t).join(segment),
        None => temp_dir.join(segment),
    }
}
