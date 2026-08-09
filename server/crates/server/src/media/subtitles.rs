//! Subtitle serving under /api/player/v1.

use axum::extract::{Path, Query, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use serde::Deserialize;

use crate::media::auth::authorize;
use crate::AppState;

#[derive(Debug, Deserialize)]
pub struct SubtitleQuery {
    pub format: Option<String>,
    pub token: Option<String>,
}

pub async fn serve(
    State(state): State<AppState>,
    Path((file_id, track_id)): Path<(String, String)>,
    Query(query): Query<SubtitleQuery>,
    headers: HeaderMap,
) -> Response {
    if let Err(status) = authorize(&state.issuer, &headers, query.token.as_deref()) {
        return status.into_response();
    }

    // subtitle_controller.ex:96 defaults to srt; the contract's `url` field
    // defaults to vtt and always sends the parameter, so this default is only
    // reached by a hand-written request.
    // Every text format SubtitleFormat can render into a URL has to be
    // servable here, or `SubtitleTrack.url` hands clients a link that 400s.
    // ssa and ass are the same format, which is why the scan already collapses
    // them (ffprobe.rs normalize_subtitle_format).
    //
    // pgs and vobsub are image-based and have no text rendering, so there is
    // nothing to convert to and they stay a 400. `unknown` is not a format at
    // all. Neither is reachable from the player, which only ever asks for VTT.
    let format = match query.format.as_deref().unwrap_or("srt") {
        f @ ("srt" | "vtt" | "ass") => f,
        "ssa" => "ass",
        _ => return StatusCode::BAD_REQUEST.into_response(),
    };

    let Ok(file) = mydia_api::streaming::resolve_file(&state.db, "file", &file_id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };

    // An external track id is a uuid; an embedded one is a stream index.
    let bytes = match mydia_db::external_subtitles::find(&state.db, &track_id).await {
        Ok(Some(sub)) if sub.media_file_id == file.id => {
            mydia_streaming::subtitles::convert(&sub.path, format).await
        }
        // A row that belongs to another file is refused rather than served.
        // Elixir maps extractor.ex:97-105's :unauthorized to HTTP 403; this
        // answers 404 so a wrong-file probe does not confirm the track exists.
        Ok(Some(_)) => return StatusCode::NOT_FOUND.into_response(),
        Ok(None) if track_id.chars().all(|c| c.is_ascii_digit()) => {
            mydia_streaming::subtitles::extract_embedded(&file.path, &track_id, format).await
        }
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(error) => {
            tracing::error!(%error, "could not read the subtitle row");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };

    match bytes {
        Ok(bytes) => (
            StatusCode::OK,
            [
                (header::CONTENT_TYPE, mime_for(format).to_string()),
                (
                    header::CONTENT_DISPOSITION,
                    format!("inline; filename=\"subtitle-{track_id}.{format}\""),
                ),
            ],
            bytes,
        )
            .into_response(),

        Err(error) => {
            tracing::error!(%error, track_id, "subtitle extraction failed");
            StatusCode::NOT_FOUND.into_response()
        }
    }
}

/// subtitle_controller.ex:249-251.
fn mime_for(format: &str) -> &'static str {
    match format {
        "vtt" => "text/vtt; charset=utf-8",
        _ => "text/plain; charset=utf-8",
    }
}
