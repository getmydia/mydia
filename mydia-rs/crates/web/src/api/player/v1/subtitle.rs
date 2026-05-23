//! `/api/player/v1/subtitles/*` — subtitle track listing + extraction.
//!
//! Port of `MydiaWeb.Api.Player.V1.SubtitleController` from
//! `lib/mydia_web/controllers/api/player/v1/subtitle_controller.ex`.
//!
//! `index` is wired: resolves the media file's absolute path via the
//! same SQL projection the stream controller uses, then calls
//! `mydia_rs_subtitles::extractor::list_embedded_tracks` (which shells
//! out to `ffprobe`). External subtitle rows are not yet modelled on
//! the Rust side so the response carries only `embedded: true`
//! entries. Matches Phoenix's shape but with the external set empty.
//!
//! `show` (single-track extraction) is still 501 — it needs an
//! on-disk extraction location, a cache key strategy, and the
//! external-subtitle path resolution, none of which exist yet on the
//! Rust side. TODO marker stays in place.

use std::path::PathBuf;

use axum::{
    extract::Path,
    http::StatusCode,
    middleware::from_fn,
    response::{IntoResponse, Response},
    routing::get,
    Extension, Json, Router,
};
use mydia_rs_subtitles::extractor::list_embedded_tracks;
use serde_json::json;

use crate::api::auth_layer::api_key_auth;
use crate::api::v1::{json_error, not_implemented};
use crate::WebState;

pub fn router() -> Router {
    Router::new()
        .route("/api/player/v1/subtitles/{type}/{id}", get(index))
        .route("/api/player/v1/subtitles/{type}/{id}/{track}", get(show))
        .layer(from_fn(api_key_auth))
}

async fn index(
    Extension(state): Extension<WebState>,
    Path((kind, id)): Path<(String, String)>,
) -> Response {
    let lookup = match kind.as_str() {
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

    let path = match lookup {
        Ok(Some(path)) => path,
        Ok(None) => return json_error(StatusCode::NOT_FOUND, "No media files available"),
        Err(err) => {
            tracing::error!(error = ?err, kind, id, "subtitle.index db error");
            return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error");
        }
    };

    let tracks = match list_embedded_tracks(&path).await {
        Ok(tracks) => tracks,
        Err(err) => {
            // ffprobe failure is logged but we degrade to an empty
            // track list — the player should still see a 200 with no
            // tracks rather than failing the whole subtitle UI.
            tracing::warn!(error = ?err, ?path, "ffprobe failed; returning empty track list");
            Vec::new()
        }
    };

    let payload: Vec<serde_json::Value> = tracks
        .iter()
        .map(|t| {
            json!({
                "track_id": t.track_id,
                "language": t.language,
                "title": t.title,
                "format": t.format,
                "embedded": true,
            })
        })
        .collect();

    (StatusCode::OK, Json(json!({ "data": payload }))).into_response()
}

async fn show(Path((_kind, _id, _track)): Path<(String, String, String)>) -> Response {
    not_implemented("U33.player.subtitles.show")
}

async fn lookup_file(state: &WebState, id: &str) -> Result<Option<PathBuf>, sqlx::Error> {
    lookup_path(
        state,
        "WHERE mf.id = $1 AND mf.trashed_at IS NULL LIMIT 1",
        id,
    )
    .await
}

async fn lookup_first_for_movie(
    state: &WebState,
    id: &str,
) -> Result<Option<PathBuf>, sqlx::Error> {
    lookup_path(
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
) -> Result<Option<PathBuf>, sqlx::Error> {
    lookup_path(
        state,
        "WHERE mf.episode_id = $1 AND mf.trashed_at IS NULL \
         ORDER BY mf.inserted_at ASC LIMIT 1",
        id,
    )
    .await
}

async fn lookup_path(
    state: &WebState,
    where_clause: &str,
    id: &str,
) -> Result<Option<PathBuf>, sqlx::Error> {
    use mydia_rs_db::Db;

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
        {where_clause}
        "
    );

    let abs_path: Option<Option<String>> = match &state.db {
        Db::Sqlite(pool) => {
            let sql_sqlite = sql.replace("$1", "?");
            sqlx::query_scalar(&sql_sqlite)
                .bind(id)
                .fetch_optional(pool)
                .await?
        }
        Db::Postgres(pool) => {
            sqlx::query_scalar(&sql)
                .bind(id)
                .fetch_optional(pool)
                .await?
        }
    };

    Ok(abs_path.flatten().map(PathBuf::from))
}
