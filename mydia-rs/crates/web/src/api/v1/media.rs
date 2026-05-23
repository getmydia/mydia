//! `/api/v1/media/:id` — fetch + manual match.
//!
//! Port of `MydiaWeb.Api.MediaController` from
//! `lib/mydia_web/controllers/api/media_controller.ex`. The `show`
//! handler returns the same JSON shape Phoenix did, minus the
//! `episodes` preload (which costs an extra round-trip and isn't
//! consumed by the Flutter player on this endpoint — the player uses
//! GraphQL `tvShow(id:) { seasons { episodes } }` for that).
//!
//! `match` ports as a U33 follow-up because it depends on
//! `mydia_rs_metadata` provider lookup + the media-update pipeline,
//! which haven't grown the manual-override entry point yet.

use axum::{
    extract::Path,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Extension, Json, Router,
};
use serde_json::json;

use crate::api::v1::{json_error, not_implemented};
use crate::WebState;

pub fn router() -> Router {
    Router::new()
        .route("/api/v1/media/{id}", get(show))
        .route("/api/v1/media/{id}/match", post(match_handler))
}

async fn show(Extension(state): Extension<WebState>, Path(id): Path<String>) -> Response {
    match lookup_media_item(&state, &id).await {
        Ok(Some(row)) => {
            let body = json!({ "data": serialize_media_item(&row) });
            (StatusCode::OK, Json(body)).into_response()
        }
        Ok(None) => json_error(StatusCode::NOT_FOUND, "Media item not found"),
        Err(err) => {
            tracing::error!(error = ?err, id, "media.show db error");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error")
        }
    }
}

async fn match_handler(Path(_id): Path<String>) -> Response {
    not_implemented("U33.media.match")
}

/// Minimal projection of the `media_items` row — only the columns the
/// REST `show` response needs. The full struct lives in
/// `mydia_rs_models::MediaItem`; using a narrower row keeps this
/// handler independent of the model crate's `FromRow` impl, which
/// requires the join shape and includes columns the JSON response
/// doesn't expose.
#[derive(sqlx::FromRow)]
struct MediaItemRow {
    id: String,
    title: Option<String>,
    r#type: Option<String>,
    year: Option<i64>,
    tmdb_id: Option<String>,
    tvdb_id: Option<String>,
    overview: Option<String>,
    poster_url: Option<String>,
    backdrop_url: Option<String>,
    runtime: Option<i64>,
    status: Option<String>,
    monitored: Option<bool>,
    library_path_id: Option<String>,
    quality_profile_id: Option<String>,
    inserted_at: Option<String>,
    updated_at: Option<String>,
}

async fn lookup_media_item(
    state: &WebState,
    id: &str,
) -> Result<Option<MediaItemRow>, sqlx::Error> {
    use mydia_rs_db::Db;

    let sql = "
        SELECT
          id, title, type, year, tmdb_id, tvdb_id, overview, poster_url,
          backdrop_url, runtime, status, monitored, library_path_id,
          quality_profile_id, inserted_at, updated_at
        FROM media_items
        WHERE id = $1
        LIMIT 1
    ";

    match &state.db {
        Db::Sqlite(pool) => {
            let sql_sqlite = sql.replace("$1", "?");
            sqlx::query_as::<_, MediaItemRow>(&sql_sqlite)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, MediaItemRow>(sql)
                .bind(id)
                .fetch_optional(pool)
                .await
        }
    }
}

fn serialize_media_item(row: &MediaItemRow) -> serde_json::Value {
    json!({
        "id": row.id,
        "title": row.title,
        "type": row.r#type,
        "year": row.year,
        "tmdb_id": row.tmdb_id,
        "tvdb_id": row.tvdb_id,
        "overview": row.overview,
        "poster_url": row.poster_url,
        "backdrop_url": row.backdrop_url,
        "runtime": row.runtime,
        "status": row.status,
        "monitored": row.monitored.unwrap_or(false),
        "library_path_id": row.library_path_id,
        "quality_profile_id": row.quality_profile_id,
        "inserted_at": row.inserted_at,
        "updated_at": row.updated_at,
        "episodes": serde_json::Value::Null,
    })
}
