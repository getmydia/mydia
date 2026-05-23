//! `/api/player/v1/subtitles/*` — subtitle track listing + extraction.
//!
//! Port of `MydiaWeb.Api.Player.V1.SubtitleController` from
//! `lib/mydia_web/controllers/api/player/v1/subtitle_controller.ex`.
//!
//! `index`: resolves the media file's absolute path via the same SQL
//! projection the stream controller uses, then merges the
//! `ffprobe`-discovered embedded tracks (via
//! `mydia_rs_subtitles::extractor::list_embedded_tracks`) with the
//! external `subtitles`-table sidecar rows (via
//! `mydia_rs_subtitles::external::list_external_tracks`). Wire shape
//! matches Phoenix's `Mydia.Subtitles.Extractor.list_subtitle_tracks/2`.
//!
//! `show`: extracts a single subtitle track and serves it. Track id
//! decoding mirrors Phoenix: integer means embedded ffmpeg stream
//! index, anything else (including UUIDs) is a `subtitles.id` lookup.
//!
//! Cache layout for embedded extractions: rooted at
//! `WebState.generated_media_path` (operator-configurable, same env
//! var as thumbnails). Per-track files live at
//! `<base>/subtitles/<media_file_id>/<track_id>.<ext>`. Atomic
//! `.tmp` -> rename so concurrent requests don't tear. A weak `ETag`
//! based on the cache file's `(size, mtime)` lets the player
//! short-circuit subsequent fetches with `If-None-Match`.

use std::path::{Path, PathBuf};

use axum::{
    body::Body,
    extract::{Path as AxumPath, Query},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    middleware::from_fn,
    response::{IntoResponse, Response},
    routing::get,
    Extension, Json, Router,
};
use mydia_rs_subtitles::{
    external::{get_external_track_for_media_file, list_external_tracks},
    extractor::{
        cache_path_for, content_type_for, extract_to_cache, list_embedded_tracks,
        normalize_subtitle_format, output_extension_for,
    },
};
use serde::Deserialize;
use serde_json::json;
use tokio_util::io::ReaderStream;

use crate::api::auth_layer::api_key_auth;
use crate::api::v1::json_error;
use crate::WebState;

pub fn router() -> Router {
    Router::new()
        .route("/api/player/v1/subtitles/{type}/{id}", get(index))
        .route("/api/player/v1/subtitles/{type}/{id}/{track}", get(show))
        .layer(from_fn(api_key_auth))
}

#[derive(Debug, Default, Deserialize)]
struct ShowQuery {
    /// Output container override. Phoenix accepts `srt|vtt|ass`;
    /// anything else falls through to `srt` to match ffmpeg's codec
    /// fallback. Only consulted for embedded tracks — external files
    /// are served as-is in their stored format.
    format: Option<String>,
}

async fn index(
    Extension(state): Extension<WebState>,
    AxumPath((kind, id)): AxumPath<(String, String)>,
) -> Response {
    let resolved = match kind.as_str() {
        "movie" => lookup_first_for_movie(&state, &id).await,
        "episode" => lookup_first_for_episode(&state, &id).await,
        "file" => lookup_file(&state, &id).await,
        _ => {
            return json_error(
                StatusCode::BAD_REQUEST,
                "Invalid type. Use 'movie', 'episode', or 'file'",
            );
        }
    };

    let mf = match resolved {
        Ok(Some(mf)) => mf,
        Ok(None) => return json_error(StatusCode::NOT_FOUND, "No media files available"),
        Err(err) => {
            tracing::error!(error = ?err, kind, id, "subtitle.index db error");
            return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error");
        }
    };

    let embedded = match list_embedded_tracks(&mf.absolute_path).await {
        Ok(tracks) => tracks,
        Err(err) => {
            // ffprobe failure is logged but we degrade to an empty
            // track list — the player should still see a 200 with
            // external tracks (if any) rather than failing the
            // whole subtitle UI.
            tracing::warn!(
                error = ?err,
                path = ?mf.absolute_path,
                "ffprobe failed; returning empty embedded track list"
            );
            Vec::new()
        }
    };

    let external = match list_external_tracks(&state.db, &mf.media_file_id).await {
        Ok(rows) => rows,
        Err(err) => {
            tracing::error!(error = ?err, media_file_id = %mf.media_file_id, "subtitle.index external lookup failed");
            Vec::new()
        }
    };

    let mut payload: Vec<serde_json::Value> = embedded
        .iter()
        .map(|t| {
            // Normalize the ffprobe codec name to the player's
            // format vocabulary (srt/ass/vtt/pgs/vobsub/unknown).
            // Phoenix does this server-side; keep parity.
            let format = normalize_subtitle_format(&t.format);
            json!({
                "track_id": t.track_id,
                "language": t.language,
                "title": t.title,
                "format": format,
                "embedded": true,
            })
        })
        .collect();

    payload.extend(external.iter().map(|t| {
        json!({
            "track_id": t.track_id,
            "language": t.language,
            "title": format_external_title(&t.language),
            "format": t.format,
            "embedded": false,
        })
    }));

    (StatusCode::OK, Json(json!({ "data": payload }))).into_response()
}

async fn show(
    Extension(state): Extension<WebState>,
    AxumPath((kind, id, track)): AxumPath<(String, String, String)>,
    Query(query): Query<ShowQuery>,
    headers: HeaderMap,
) -> Response {
    let resolved = match kind.as_str() {
        "movie" => lookup_first_for_movie(&state, &id).await,
        "episode" => lookup_first_for_episode(&state, &id).await,
        "file" => lookup_file(&state, &id).await,
        _ => {
            return json_error(
                StatusCode::BAD_REQUEST,
                "Invalid type. Use 'movie', 'episode', or 'file'",
            );
        }
    };

    let mf = match resolved {
        Ok(Some(mf)) => mf,
        Ok(None) => return json_error(StatusCode::NOT_FOUND, "No media files available"),
        Err(err) => {
            tracing::error!(error = ?err, kind, id, "subtitle.show db error");
            return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error");
        }
    };

    match parse_track_param(&track) {
        TrackParam::Embedded(track_id) => {
            serve_embedded(&state, &mf, track_id, query.format.as_deref(), &headers).await
        }
        TrackParam::External(subtitle_id) => {
            serve_external(&state, &mf, &subtitle_id, &headers).await
        }
    }
}

#[derive(Debug)]
enum TrackParam {
    Embedded(i32),
    External(String),
}

/// Decode the `:track` URL segment. Pure integer => embedded stream
/// index; anything else (UUID, slug, etc.) => external subtitle id.
/// Matches the Phoenix `parse_track_id/1` helper.
fn parse_track_param(track: &str) -> TrackParam {
    match track.parse::<i32>() {
        Ok(idx) if idx >= 0 => TrackParam::Embedded(idx),
        // Negative integers fall through to external; a `subtitles.id`
        // UUID would never parse as i32 anyway, but this guards
        // against `?track=-1` getting routed to the embedded path.
        _ => TrackParam::External(track.to_string()),
    }
}

async fn serve_embedded(
    state: &WebState,
    mf: &ResolvedMediaFile,
    track_id: i32,
    requested_format: Option<&str>,
    request_headers: &HeaderMap,
) -> Response {
    let format = requested_format.unwrap_or("srt");
    let cache_path = cache_path_for(
        &state.generated_media_path,
        &mf.media_file_id,
        track_id,
        format,
    );

    // Verify the source media file actually exists on disk before
    // shelling out to ffmpeg; otherwise the extraction error is the
    // first thing the operator sees in logs.
    if tokio::fs::metadata(&mf.absolute_path).await.is_err() {
        return json_error(StatusCode::NOT_FOUND, "Media file not found on disk");
    }

    if let Err(err) = extract_to_cache(&mf.absolute_path, track_id, &cache_path, format).await {
        tracing::error!(
            error = ?err,
            media_file_id = %mf.media_file_id,
            track_id,
            "subtitle extraction failed"
        );
        return json_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Failed to extract subtitle track",
        );
    }

    let content_type = content_type_for(format);
    let filename = format!("subtitle-{track_id}.{}", output_extension_for(format));
    serve_cached_file(&cache_path, content_type, &filename, request_headers).await
}

async fn serve_external(
    state: &WebState,
    mf: &ResolvedMediaFile,
    subtitle_id: &str,
    request_headers: &HeaderMap,
) -> Response {
    let row =
        match get_external_track_for_media_file(&state.db, subtitle_id, &mf.media_file_id).await {
            Ok(Some(row)) => row,
            Ok(None) => return json_error(StatusCode::NOT_FOUND, "Subtitle track not found"),
            Err(err) => {
                tracing::error!(
                    error = ?err,
                    subtitle_id,
                    media_file_id = %mf.media_file_id,
                    "external subtitle lookup failed"
                );
                return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error");
            }
        };

    let path = PathBuf::from(&row.file_path);
    if tokio::fs::metadata(&path).await.is_err() {
        return json_error(StatusCode::NOT_FOUND, "Subtitle file not found on disk");
    }

    let content_type = content_type_for(&row.format);
    let filename = format!(
        "subtitle-{}.{}",
        row.track_id,
        output_extension_for(&row.format)
    );
    serve_cached_file(&path, content_type, &filename, request_headers).await
}

/// Serve a subtitle file off disk with a weak `ETag` + Cache-Control,
/// honoring `If-None-Match` for 304 short-circuits. The `ETag` is a
/// `(size, mtime_micros)` pair so a regenerated cache file (after
/// e.g. a manual cache eviction) yields a fresh tag without paying
/// for a content hash. Mirrors what axum's static-file middleware
/// does for the operator-facing routes, just inlined for control over
/// the content-disposition header.
async fn serve_cached_file(
    path: &Path,
    content_type: &'static str,
    filename: &str,
    request_headers: &HeaderMap,
) -> Response {
    let metadata = match tokio::fs::metadata(path).await {
        Ok(m) => m,
        Err(err) => {
            tracing::warn!(error = ?err, ?path, "subtitle cache stat failed");
            return json_error(StatusCode::NOT_FOUND, "Subtitle file not found on disk");
        }
    };

    let etag = compute_weak_etag(&metadata);

    // If-None-Match short-circuit. The player keeps a per-track ETag
    // and replays it on every seek; a 304 lets it skip the body
    // download entirely.
    if let Some(if_none_match) = request_headers.get(header::IF_NONE_MATCH) {
        if let Ok(value) = if_none_match.to_str() {
            if etag_matches(value, &etag) {
                let mut response = Response::new(Body::empty());
                *response.status_mut() = StatusCode::NOT_MODIFIED;
                if let Ok(tag) = HeaderValue::from_str(&etag) {
                    response.headers_mut().insert(header::ETAG, tag);
                }
                return response;
            }
        }
    }

    let Ok(file) = tokio::fs::File::open(path).await else {
        return json_error(StatusCode::NOT_FOUND, "Subtitle file not found on disk");
    };

    let stream = ReaderStream::new(file);
    let body = Body::from_stream(stream);

    let mut response = Response::new(body);
    *response.status_mut() = StatusCode::OK;
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    headers.insert(
        header::CONTENT_LENGTH,
        HeaderValue::from_str(&metadata.len().to_string()).expect("len is ASCII"),
    );
    if let Ok(disposition) = HeaderValue::from_str(&format!("inline; filename=\"{filename}\"")) {
        headers.insert(header::CONTENT_DISPOSITION, disposition);
    }
    if let Ok(tag) = HeaderValue::from_str(&etag) {
        headers.insert(header::ETAG, tag);
    }
    // Subtitle files are large-grained immutable artefacts (one file
    // per track per media file). Mirror the thumbnail handler's
    // long-lived Cache-Control so a player that re-mounts the track
    // doesn't re-fetch the body either.
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=31536000"),
    );
    response
}

fn compute_weak_etag(metadata: &std::fs::Metadata) -> String {
    // `(size, mtime_micros)` is enough for cache invalidation here: an
    // extraction rewrite swaps the file's mtime via the `.tmp` ->
    // rename, and an external sidecar upload changes mtime too. Weak
    // (`W/`) because we don't guarantee byte-for-byte equivalence
    // across ffmpeg versions.
    let size = metadata.len();
    let mtime_micros = metadata
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_micros());
    format!("W/\"{size:x}-{mtime_micros:x}\"")
}

/// Per RFC 7232 §3.2 an `If-None-Match` may carry a comma-separated
/// list of `ETag`s or the wildcard `*`. Match against any element
/// that equals our weak tag — clients commonly drop the `W/` prefix
/// when echoing back, so accept both spellings.
fn etag_matches(header_value: &str, our_tag: &str) -> bool {
    let our_stripped = our_tag.trim_start_matches("W/");
    for part in header_value.split(',') {
        let trimmed = part.trim();
        if trimmed == "*" {
            return true;
        }
        let stripped = trimmed.trim_start_matches("W/");
        if stripped == our_stripped {
            return true;
        }
    }
    false
}

/// Render a display title for an external track. Mirrors Phoenix's
/// `format_external_title/1`: lowercase language code -> spelled-out
/// English label + " (External)" suffix. Falls through to upper-cased
/// raw code for codes we don't have a mapping for, which is the
/// `format_language_name/1` fallback in Elixir.
fn format_external_title(language: &str) -> String {
    let name = match language {
        "eng" | "en" => "English",
        "spa" | "es" => "Spanish",
        "fra" | "fr" => "French",
        "deu" | "de" => "German",
        "ita" | "it" => "Italian",
        "por" | "pt" => "Portuguese",
        "jpn" | "ja" => "Japanese",
        "kor" | "ko" => "Korean",
        "chi" | "zh" => "Chinese",
        "rus" | "ru" => "Russian",
        "ara" | "ar" => "Arabic",
        "und" => "Unknown",
        other => return format!("{} (External)", other.to_uppercase()),
    };
    format!("{name} (External)")
}

// ---------------------------------------------------------------------
// Media-file resolution helpers. Mirrors the stream controller's SQL
// projection. Lookups return the id + absolute path together so the
// extraction handler has both — id for the cache key, path for ffmpeg.
// ---------------------------------------------------------------------

#[derive(Debug)]
struct ResolvedMediaFile {
    media_file_id: String,
    absolute_path: PathBuf,
}

async fn lookup_file(state: &WebState, id: &str) -> Result<Option<ResolvedMediaFile>, sqlx::Error> {
    lookup_media_file(
        state,
        "WHERE mf.id = $1 AND mf.trashed_at IS NULL LIMIT 1",
        id,
    )
    .await
}

async fn lookup_first_for_movie(
    state: &WebState,
    id: &str,
) -> Result<Option<ResolvedMediaFile>, sqlx::Error> {
    lookup_media_file(
        state,
        "WHERE mf.media_item_id = $1 AND mf.episode_id IS NULL AND mf.trashed_at IS NULL \
         ORDER BY mf.inserted_at ASC LIMIT 1",
        id,
    )
    .await
}

async fn lookup_first_for_episode(
    state: &WebState,
    id: &str,
) -> Result<Option<ResolvedMediaFile>, sqlx::Error> {
    lookup_media_file(
        state,
        "WHERE mf.episode_id = $1 AND mf.trashed_at IS NULL \
         ORDER BY mf.inserted_at ASC LIMIT 1",
        id,
    )
    .await
}

async fn lookup_media_file(
    state: &WebState,
    where_clause: &str,
    id: &str,
) -> Result<Option<ResolvedMediaFile>, sqlx::Error> {
    use mydia_rs_db::Db;

    let sql = format!(
        "
        SELECT
          mf.id AS id,
          CASE
            WHEN mf.path IS NOT NULL THEN mf.path
            WHEN lp.path IS NOT NULL AND mf.relative_path IS NOT NULL
              THEN lp.path || '/' || mf.relative_path
            ELSE NULL
          END AS abs_path
        FROM media_files mf
        LEFT JOIN library_paths lp ON lp.id = mf.library_path_id
        {where_clause}
        "
    );

    let row: Option<(String, Option<String>)> = match &state.db {
        Db::Sqlite(pool) => {
            let sql_sqlite = sql.replace("$1", "?");
            sqlx::query_as(&sql_sqlite)
                .bind(id)
                .fetch_optional(pool)
                .await?
        }
        Db::Postgres(pool) => sqlx::query_as(&sql).bind(id).fetch_optional(pool).await?,
    };

    Ok(row.and_then(|(media_file_id, abs_path)| {
        abs_path.map(|p| ResolvedMediaFile {
            media_file_id,
            absolute_path: PathBuf::from(p),
        })
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_track_param_integer_is_embedded() {
        assert!(matches!(parse_track_param("0"), TrackParam::Embedded(0)));
        assert!(matches!(parse_track_param("42"), TrackParam::Embedded(42)));
    }

    #[test]
    fn parse_track_param_uuid_is_external() {
        let uuid = "550e8400-e29b-41d4-a716-446655440000";
        match parse_track_param(uuid) {
            TrackParam::External(s) => assert_eq!(s, uuid),
            TrackParam::Embedded(_) => panic!("expected External"),
        }
    }

    #[test]
    fn parse_track_param_negative_falls_through_to_external() {
        match parse_track_param("-1") {
            TrackParam::External(s) => assert_eq!(s, "-1"),
            TrackParam::Embedded(_) => panic!("negative should not match Embedded"),
        }
    }

    #[test]
    fn etag_matches_strips_weak_prefix() {
        let our = "W/\"1a-2b\"";
        assert!(etag_matches("W/\"1a-2b\"", our));
        assert!(etag_matches("\"1a-2b\"", our));
        assert!(etag_matches("*", our));
        assert!(etag_matches("W/\"other\", \"1a-2b\"", our));
        assert!(!etag_matches("\"different\"", our));
    }

    #[test]
    fn format_external_title_uses_language_map() {
        assert_eq!(format_external_title("eng"), "English (External)");
        assert_eq!(format_external_title("ja"), "Japanese (External)");
        // Unknown codes fall back to upper-cased raw.
        assert_eq!(format_external_title("nor"), "NOR (External)");
    }

    #[test]
    fn compute_weak_etag_produces_weak_prefix() {
        // Use a stable temp file so we can inspect the metadata.
        let tmp = tempfile::NamedTempFile::new().expect("tempfile");
        let meta = std::fs::metadata(tmp.path()).expect("metadata");
        let etag = compute_weak_etag(&meta);
        assert!(etag.starts_with("W/\""));
        assert!(etag.ends_with('"'));
    }
}
