use axum::Router;
use axum_embed::{FallbackBehavior, ServeEmbed};
use rust_embed::RustEmbed;

#[derive(RustEmbed, Clone)]
#[folder = "../../frontend/dist"]
struct Assets;

pub fn spa_router() -> Router {
    let serve_assets = ServeEmbed::<Assets>::with_parameters(
        Some("index.html".to_string()),
        FallbackBehavior::Ok,
        Some("index.html".to_string()),
    );

    Router::new().fallback_service(serve_assets)
}
