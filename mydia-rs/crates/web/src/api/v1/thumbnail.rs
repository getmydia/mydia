//! `/api/v1/media/:id/thumbnails.{vtt,jpg}` — seek-preview sprite +
//! VTT serving.
//!
//! Port of `MydiaWeb.Api.ThumbnailController` from
//! `lib/mydia_web/controllers/api/thumbnail_controller.ex`. The
//! generated-media base directory is operator-configurable in
//! Phoenix via the `:mydia, :generated_media_path` Application env
//! key; on the Rust side that path resolves once at boot from the
//! `MYDIA_GENERATED_MEDIA_PATH` environment variable (the same one
//! Phoenix reads via release env) and is stored on [`WebState`] so
//! the per-request hot path is allocation-free. Defaults to
//! `priv/generated` to match Phoenix's dev-mode output.

use std::path::{Path, PathBuf};

use axum::{
    body::Body,
    extract::Path as AxumPath,
    http::{header, HeaderValue, StatusCode},
    middleware::from_fn,
    response::{IntoResponse, Response},
    routing::get,
    Extension, Router,
};
use tokio_util::io::ReaderStream;

use crate::api::auth_layer::api_key_auth;
use crate::api::v1::json_error;
use crate::WebState;

/// Mount the thumbnail routes.
pub fn router() -> Router {
    Router::new()
        .route("/api/v1/media/{id}/thumbnails.vtt", get(show_vtt))
        .route("/api/v1/media/{id}/thumbnails.jpg", get(show_sprite))
        .layer(from_fn(api_key_auth))
}

async fn show_vtt(
    Extension(state): Extension<WebState>,
    AxumPath(media_file_id): AxumPath<String>,
) -> Response {
    serve_blob(&state, &media_file_id, BlobKind::Vtt).await
}

async fn show_sprite(
    Extension(state): Extension<WebState>,
    AxumPath(media_file_id): AxumPath<String>,
) -> Response {
    serve_blob(&state, &media_file_id, BlobKind::Sprite).await
}

#[derive(Debug, Clone, Copy)]
enum BlobKind {
    Vtt,
    Sprite,
}

impl BlobKind {
    fn subdir(self) -> &'static str {
        match self {
            Self::Vtt => "vtt",
            Self::Sprite => "sprites",
        }
    }

    fn extension(self) -> &'static str {
        match self {
            Self::Vtt => "vtt",
            Self::Sprite => "jpg",
        }
    }

    fn content_type(self) -> &'static str {
        match self {
            Self::Vtt => "text/vtt",
            Self::Sprite => "image/jpeg",
        }
    }
}

async fn serve_blob(state: &WebState, media_file_id: &str, kind: BlobKind) -> Response {
    let checksum = match lookup_blob_checksum(state, media_file_id, kind).await {
        Ok(Some(Some(checksum))) => checksum,
        Ok(Some(None) | None) => {
            return json_error(
                StatusCode::NOT_FOUND,
                "No thumbnails available for this file",
            );
        }
        Err(err) => {
            tracing::error!(error = ?err, media_file_id, "thumbnail db error");
            return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Database error");
        }
    };

    let path = generated_media_path(&state.generated_media_path, kind, &checksum);

    let Ok(file) = tokio::fs::File::open(&path).await else {
        tracing::warn!(
            media_file_id,
            path = ?path,
            "thumbnail blob missing on disk"
        );
        return json_error(StatusCode::NOT_FOUND, "Thumbnail file not found on disk");
    };

    let stream = ReaderStream::new(file);
    let body = Body::from_stream(stream);
    let mut response = Response::new(body);
    *response.status_mut() = StatusCode::OK;
    let headers = response.headers_mut();
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=31536000"),
    );
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static(kind.content_type()),
    );
    response.into_response()
}

async fn lookup_blob_checksum(
    state: &WebState,
    media_file_id: &str,
    kind: BlobKind,
) -> Result<Option<Option<String>>, sea_orm::DbErr> {
    use mydia_rs_db::types::UuidText;
    use mydia_rs_entities::media_files;
    use sea_orm::entity::prelude::*;
    use sea_orm::sea_query::{Expr, ExprTrait};

    let Some(wrapper) = uuid::Uuid::parse_str(media_file_id)
        .ok()
        .map(UuidText::from)
    else {
        return Ok(None);
    };
    let backend = state.db.get_database_backend();
    let Some(model) = media_files::Entity::find()
        .filter(Expr::col(media_files::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .one(&state.db)
        .await?
    else {
        return Ok(None);
    };
    let checksum = match kind {
        BlobKind::Vtt => model.vtt_blob,
        BlobKind::Sprite => model.sprite_blob,
    };
    Ok(Some(checksum))
}

/// Resolve a generated-media checksum to an absolute path. Mirrors
/// `Mydia.Library.GeneratedMedia.build_path/2`: two-tier sharding off
/// the first two and next two checksum characters.
fn generated_media_path(base: &Path, kind: BlobKind, checksum: &str) -> PathBuf {
    let tier1 = checksum.get(0..2).unwrap_or("");
    let tier2 = checksum.get(2..4).unwrap_or("");

    base.join(kind.subdir())
        .join(tier1)
        .join(tier2)
        .join(format!("{checksum}.{}", kind.extension()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vtt_path_resolves_with_tier_sharding() {
        let base = PathBuf::from("/tmp/generated");
        let path = generated_media_path(&base, BlobKind::Vtt, "abcdef0123456789");
        assert_eq!(
            path,
            PathBuf::from("/tmp/generated/vtt/ab/cd/abcdef0123456789.vtt")
        );
    }

    #[test]
    fn sprite_path_uses_jpg_extension() {
        let base = PathBuf::from("/tmp/generated");
        let path = generated_media_path(&base, BlobKind::Sprite, "deadbeefcafebabe");
        assert_eq!(
            path,
            PathBuf::from("/tmp/generated/sprites/de/ad/deadbeefcafebabe.jpg")
        );
    }
}
