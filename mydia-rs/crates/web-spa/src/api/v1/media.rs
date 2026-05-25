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
    middleware::from_fn,
    response::{IntoResponse, Response},
    routing::{get, post},
    Extension, Json, Router,
};
use serde_json::json;

use crate::api::auth_layer::api_key_auth;
use crate::api::v1::{json_error, not_implemented};
use crate::WebState;

pub fn router() -> Router {
    Router::new()
        .route("/api/v1/media/{id}", get(show))
        .route("/api/v1/media/{id}/match", post(match_handler))
        .layer(from_fn(api_key_auth))
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

async fn lookup_media_item(
    state: &WebState,
    id: &str,
) -> Result<Option<mydia_rs_entities::media_items::Model>, sea_orm::DbErr> {
    use mydia_rs_db::types::UuidText;
    use mydia_rs_entities::media_items;
    use sea_orm::entity::prelude::*;
    use sea_orm::sea_query::{Expr, ExprTrait};

    let Some(wrapper) = uuid::Uuid::parse_str(id).ok().map(UuidText::from) else {
        return Ok(None);
    };
    let backend = state.db.get_database_backend();
    media_items::Entity::find()
        .filter(Expr::col(media_items::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .one(&state.db)
        .await
}

fn serialize_media_item(row: &mydia_rs_entities::media_items::Model) -> serde_json::Value {
    // The entity has columns: id, type, title, year, tmdb_id, imdb_id,
    // metadata (json text), monitored, quality_profile_id, category,
    // category_override, monitoring_preset, tvdb_id, inserted_at, updated_at.
    // The pre-conversion query referenced `overview`, `poster_url`,
    // `backdrop_url`, `runtime`, `status`, `library_path_id` — none of
    // which exist as columns on the entity. The full metadata lives in
    // `metadata`, a JSON-encoded blob. Extract these from the metadata
    // JSON when present so the REST shape stays compatible.
    let meta: serde_json::Value = row
        .metadata
        .as_deref()
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or(serde_json::Value::Null);
    let extract = |key: &str| meta.get(key).cloned().unwrap_or(serde_json::Value::Null);
    json!({
        "id": row.id.to_string(),
        "title": row.title.clone(),
        "type": row.r#type.clone(),
        "year": row.year,
        "tmdb_id": row.tmdb_id,
        "tvdb_id": row.tvdb_id,
        "overview": extract("overview"),
        "poster_url": extract("poster_url"),
        "backdrop_url": extract("backdrop_url"),
        "runtime": extract("runtime"),
        "status": extract("status"),
        "monitored": row.monitored.unwrap_or(false),
        "library_path_id": serde_json::Value::Null,
        "quality_profile_id": row.quality_profile_id.as_ref().map(ToString::to_string),
        "inserted_at": row.inserted_at.0.to_rfc3339(),
        "updated_at": row.updated_at.0.to_rfc3339(),
        "episodes": serde_json::Value::Null,
    })
}
