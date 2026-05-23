//! `/api/v1/stream/*` — direct-play byte-range streaming.
//!
//! Port of `MydiaWeb.Api.StreamController` from
//! `lib/mydia_web/controllers/api/stream_controller.ex`. This module
//! covers the direct-play path (HTTP 200 / 206 with `Content-Range`
//! over a `tokio::fs::File` stream); the remux / HLS-transcode
//! branches of the Phoenix controller live in `crates/streaming/` and
//! their HTTP entry points port as a U33 follow-up slice.
//!
//! ## Routes
//!
//! - `GET /api/v1/stream/movie/:id`   — pick first `media_file` for
//!   the media item, stream it.
//! - `GET /api/v1/stream/episode/:id` — pick first `media_file` for
//!   the episode, stream it.
//! - `GET /api/v1/stream/file/:id`    — stream a specific `media_file`
//!   by id.
//! - `GET /api/v1/stream/:id`         — bare-id alias for `/file/:id`,
//!   preserved because the Phoenix router exposes it and the player
//!   uses it via a media-token URL.
//! - `GET /api/v1/stream/:content_type/:id/candidates` — return the
//!   streaming-strategy candidate list (returns `501` for now; the
//!   `crates/streaming/candidates` port hasn't grown the JSON
//!   serializer yet).
//!
//! ## Range handling
//!
//! Parses the `Range:` header via [`super::super::range_helper`],
//! returns:
//!   - `200 OK` with full body when no header is set
//!   - `206 Partial Content` with `Content-Range` when a valid range
//!     is set
//!   - `416 Range Not Satisfiable` with a `Content-Range: bytes */N`
//!     header when the range is malformed or out of bounds
//!
//! The response body is a streamed `ReaderStream` over a seeked
//! `tokio::fs::File` so 50 GiB MKVs don't get buffered in RAM.

use std::path::{Path, PathBuf};

use axum::{
    body::Body,
    extract::{Path as AxumPath, Query},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::Response,
    routing::get,
    Extension, Router,
};
use serde::Deserialize;
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;

use crate::api::range_helper::{
    calculate_range, format_content_range, get_mime_type, parse_range_header, RangeOutcome,
};
use crate::api::v1::{json_error, not_implemented};
use crate::WebState;

/// Mount the stream routes.
pub fn router() -> Router {
    Router::new()
        .route("/api/v1/stream/movie/{id}", get(stream_movie))
        .route("/api/v1/stream/episode/{id}", get(stream_episode))
        .route("/api/v1/stream/file/{id}", get(stream_file))
        .route("/api/v1/stream/{id}", get(stream_bare))
        .route(
            "/api/v1/stream/{content_type}/{id}/candidates",
            get(stream_candidates),
        )
}

/// Query parameters supported on the streaming endpoints. `strategy`
/// and `resolve=json` mirror the Phoenix controller's optional knobs;
/// only `strategy=DIRECT_PLAY` is honored today (other strategies fall
/// back to direct play for now and are tagged in the response header).
#[derive(Debug, Deserialize, Default)]
pub(crate) struct StreamQuery {
    #[serde(default)]
    strategy: Option<String>,
    /// `resolve=json` opts callers into a JSON response shape for
    /// strategies that would otherwise return a redirect (HLS today).
    /// Wired through the deserializer for parity with Phoenix but not
    /// consumed yet because the direct-play branch never redirects.
    #[serde(default)]
    #[allow(dead_code)]
    resolve: Option<String>,
}

async fn stream_movie(
    Extension(state): Extension<WebState>,
    AxumPath(media_item_id): AxumPath<String>,
    headers: HeaderMap,
    Query(query): Query<StreamQuery>,
) -> Response {
    match lookup_first_media_file_for_movie(&state, &media_item_id).await {
        Ok(Some(mf)) => stream_media_file(&mf, &headers, &query).await,
        Ok(None) => json_error(
            StatusCode::NOT_FOUND,
            "No media files available for this movie",
        ),
        Err(err) => {
            tracing::error!(error = ?err, media_item_id, "stream_movie db error");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error")
        }
    }
}

async fn stream_episode(
    Extension(state): Extension<WebState>,
    AxumPath(episode_id): AxumPath<String>,
    headers: HeaderMap,
    Query(query): Query<StreamQuery>,
) -> Response {
    match lookup_first_media_file_for_episode(&state, &episode_id).await {
        Ok(Some(mf)) => stream_media_file(&mf, &headers, &query).await,
        Ok(None) => json_error(
            StatusCode::NOT_FOUND,
            "No media files available for this episode",
        ),
        Err(err) => {
            tracing::error!(error = ?err, episode_id, "stream_episode db error");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error")
        }
    }
}

async fn stream_file(
    Extension(state): Extension<WebState>,
    AxumPath(media_file_id): AxumPath<String>,
    headers: HeaderMap,
    Query(query): Query<StreamQuery>,
) -> Response {
    match lookup_media_file(&state, &media_file_id).await {
        Ok(Some(mf)) => stream_media_file(&mf, &headers, &query).await,
        Ok(None) => json_error(StatusCode::NOT_FOUND, "Media file not found"),
        Err(err) => {
            tracing::error!(error = ?err, media_file_id, "stream_file db error");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error")
        }
    }
}

async fn stream_bare(
    Extension(state): Extension<WebState>,
    AxumPath(id): AxumPath<String>,
    headers: HeaderMap,
    Query(query): Query<StreamQuery>,
) -> Response {
    // The `/api/v1/stream/:id` route is an alias for `/file/:id`,
    // preserved for the player's media-token URLs (matches the Phoenix
    // route at `lib/mydia_web/router.ex:262`).
    stream_file(Extension(state), AxumPath(id), headers, Query(query)).await
}

async fn stream_candidates(
    Extension(_state): Extension<WebState>,
    AxumPath((_content_type, _id)): AxumPath<(String, String)>,
) -> Response {
    // The Phoenix controller delegates to `Mydia.Streaming.Candidates`,
    // which ports as part of the streaming-crate JSON surface. The
    // route is mounted so clients see the same URL; behavior follows.
    not_implemented("U33.stream.candidates")
}

/// Resolved view of a media file. Lightweight subset of the full
/// `MediaFile` row — only the columns the streaming pipeline reads
/// here. Mirrors what `MediaFile.absolute_path/1` needs.
struct ResolvedMediaFile {
    /// `path` column (legacy absolute path from the Phoenix era when
    /// media files were stored as full paths) or
    /// `library_path.path + relative_path` when the new pair is set.
    absolute_path: PathBuf,
}

async fn lookup_media_file(
    state: &WebState,
    id: &str,
) -> Result<Option<ResolvedMediaFile>, sqlx::Error> {
    use mydia_rs_db::Db;

    // Query joins media_files to library_paths so we can build the
    // absolute path in a single round-trip. The schema allows either
    // (path) or (library_path_id + relative_path); the SQL below
    // produces the absolute path inline using SQLite's `||` and
    // Postgres's `||` (both behave identically for TEXT concatenation
    // with NULL propagation).
    let sql = "
        SELECT
          CASE
            WHEN mf.path IS NOT NULL THEN mf.path
            WHEN lp.path IS NOT NULL AND mf.relative_path IS NOT NULL
              THEN lp.path || '/' || mf.relative_path
            ELSE NULL
          END AS abs_path
        FROM media_files mf
        LEFT JOIN library_paths lp ON lp.id = mf.library_path_id
        WHERE mf.id = $1 AND mf.trashed_at IS NULL
        LIMIT 1
    ";

    let abs_path: Option<Option<String>> = match &state.db {
        Db::Sqlite(pool) => {
            let sql_sqlite = sql.replace("$1", "?");
            sqlx::query_scalar(&sql_sqlite)
                .bind(id)
                .fetch_optional(pool)
                .await?
        }
        Db::Postgres(pool) => {
            sqlx::query_scalar(sql)
                .bind(id)
                .fetch_optional(pool)
                .await?
        }
    };

    Ok(abs_path.flatten().map(|p| ResolvedMediaFile {
        absolute_path: PathBuf::from(p),
    }))
}

async fn lookup_first_media_file_for_movie(
    state: &WebState,
    media_item_id: &str,
) -> Result<Option<ResolvedMediaFile>, sqlx::Error> {
    lookup_first_for_parent(state, "media_item_id", media_item_id, true).await
}

async fn lookup_first_media_file_for_episode(
    state: &WebState,
    episode_id: &str,
) -> Result<Option<ResolvedMediaFile>, sqlx::Error> {
    lookup_first_for_parent(state, "episode_id", episode_id, false).await
}

async fn lookup_first_for_parent(
    state: &WebState,
    parent_col: &str,
    parent_id: &str,
    movie: bool,
) -> Result<Option<ResolvedMediaFile>, sqlx::Error> {
    use mydia_rs_db::Db;

    // For movies we explicitly require `episode_id IS NULL` because
    // some Phoenix migration paths leave both columns populated on
    // historical rows. For episodes the parent column itself is the
    // discriminant.
    let extra_predicate = if movie {
        " AND mf.episode_id IS NULL"
    } else {
        ""
    };
    let sql = format!(
        "
        SELECT
          CASE
            WHEN mf.path IS NOT NULL THEN mf.path
            WHEN lp.path IS NOT NULL AND mf.relative_path IS NOT NULL
              THEN lp.path || '/' || mf.relative_path
            ELSE NULL
          END AS abs_path
        FROM media_files mf
        LEFT JOIN library_paths lp ON lp.id = mf.library_path_id
        WHERE mf.{parent_col} = $1
          AND mf.trashed_at IS NULL{extra_predicate}
        ORDER BY mf.inserted_at ASC
        LIMIT 1
        "
    );

    let abs_path: Option<Option<String>> = match &state.db {
        Db::Sqlite(pool) => {
            let sql_sqlite = sql.replace("$1", "?");
            sqlx::query_scalar(&sql_sqlite)
                .bind(parent_id)
                .fetch_optional(pool)
                .await?
        }
        Db::Postgres(pool) => {
            sqlx::query_scalar(&sql)
                .bind(parent_id)
                .fetch_optional(pool)
                .await?
        }
    };

    Ok(abs_path.flatten().map(|p| ResolvedMediaFile {
        absolute_path: PathBuf::from(p),
    }))
}

/// Open the media file, evaluate the `Range:` header, and produce
/// either a `200 OK` (full body), `206 Partial Content`, or `416
/// Range Not Satisfiable` response.
async fn stream_media_file(
    mf: &ResolvedMediaFile,
    headers: &HeaderMap,
    query: &StreamQuery,
) -> Response {
    serve_file(&mf.absolute_path, headers, query).await
}

/// Lower-level entry point used by both the DB-backed handlers and
/// (via `serve_file_for_tests`) the integration tests. Returns the
/// streaming response for an arbitrary path; the caller has already
/// done auth + DB lookup + path resolution.
async fn serve_file(path: &Path, headers: &HeaderMap, query: &StreamQuery) -> Response {
    let Ok(metadata) = tokio::fs::metadata(path).await else {
        return json_error(StatusCode::NOT_FOUND, "Media file not found on disk");
    };

    if !metadata.is_file() {
        return json_error(StatusCode::NOT_FOUND, "Media file not found on disk");
    }

    let file_size = metadata.len();
    let mime = get_mime_type(path);

    // Strategy header: today only `DIRECT_PLAY` is implemented; the
    // others fall through to direct play with a header note so the
    // player sees the actual mode it got rather than the one it
    // asked for.
    let strategy_label = match query.strategy.as_deref() {
        Some("DIRECT_PLAY") | None => "direct",
        Some(other) => {
            tracing::warn!(
                strategy = other,
                "stream strategy not yet implemented in mydia-rs; falling back to direct play"
            );
            "direct"
        }
    };

    let range_header = headers
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    if range_header.is_empty() {
        return full_body_response(path, file_size, mime, strategy_label).await;
    }

    match parse_range_header(range_header, file_size) {
        RangeOutcome::Range { start, end } => {
            partial_body_response(path, start, end, file_size, mime, strategy_label).await
        }
        RangeOutcome::Invalid => {
            // 416 with the canonical `Content-Range: bytes */N` so the
            // client knows the resource size. Matches Phoenix's
            // `:requested_range_not_satisfiable` arm.
            let mut response =
                json_error(StatusCode::RANGE_NOT_SATISFIABLE, "Invalid range request");
            response.headers_mut().insert(
                header::CONTENT_RANGE,
                HeaderValue::from_str(&format!("bytes */{file_size}"))
                    .expect("content-range value is ASCII"),
            );
            response
        }
    }
}

async fn full_body_response(
    path: &Path,
    file_size: u64,
    mime: &str,
    strategy_label: &str,
) -> Response {
    let Ok(file) = tokio::fs::File::open(path).await else {
        return json_error(StatusCode::NOT_FOUND, "Media file not found on disk");
    };
    let stream = ReaderStream::new(file);
    let body = Body::from_stream(stream);

    let mut response = Response::new(body);
    *response.status_mut() = StatusCode::OK;
    let headers = response.headers_mut();
    headers.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(mime).unwrap_or(HeaderValue::from_static("application/octet-stream")),
    );
    headers.insert(
        header::CONTENT_LENGTH,
        HeaderValue::from_str(&file_size.to_string()).expect("content-length is ASCII"),
    );
    headers.insert(
        "x-streaming-mode",
        HeaderValue::from_str(strategy_label).unwrap_or(HeaderValue::from_static("direct")),
    );
    response
}

async fn partial_body_response(
    path: &Path,
    start: u64,
    end: u64,
    file_size: u64,
    mime: &str,
    strategy_label: &str,
) -> Response {
    let (offset, length) = calculate_range(start, end);
    let content_range = format_content_range(start, end, file_size);

    let Ok(mut file) = tokio::fs::File::open(path).await else {
        return json_error(StatusCode::NOT_FOUND, "Media file not found on disk");
    };
    if let Err(err) = file.seek(std::io::SeekFrom::Start(offset)).await {
        tracing::error!(error = ?err, ?path, "seek failed");
        return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Seek failed");
    }
    // Take exactly `length` bytes so the response body matches the
    // declared Content-Length and Content-Range. Without this, the
    // ReaderStream would keep going past `end` if the file grew (rare
    // but possible mid-write).
    let bounded = file.take(length);
    let stream = ReaderStream::new(bounded);
    let body = Body::from_stream(stream);

    let mut response = Response::new(body);
    *response.status_mut() = StatusCode::PARTIAL_CONTENT;
    let headers = response.headers_mut();
    headers.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(mime).unwrap_or(HeaderValue::from_static("application/octet-stream")),
    );
    headers.insert(
        header::CONTENT_RANGE,
        HeaderValue::from_str(&content_range).expect("content-range is ASCII"),
    );
    headers.insert(
        header::CONTENT_LENGTH,
        HeaderValue::from_str(&length.to_string()).expect("content-length is ASCII"),
    );
    headers.insert(
        "x-streaming-mode",
        HeaderValue::from_str(strategy_label).unwrap_or(HeaderValue::from_static("direct")),
    );
    response
}

/// Public test entry point so the integration suite can exercise the
/// streaming pipeline without spinning up a database. Hidden from
/// rustdoc; the production callers always go through the DB-backed
/// route handlers.
#[doc(hidden)]
pub async fn serve_file_for_tests(path: &Path, headers: &HeaderMap) -> Response {
    serve_file(path, headers, &StreamQuery::default()).await
}
