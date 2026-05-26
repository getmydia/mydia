pub mod api;
pub mod auth;
pub mod csrf;
pub mod download_probes;
pub mod embed;
pub mod indexer_probes;
pub mod security;
pub mod server_state;
pub mod session_config;

use axum::{middleware, Extension, Router};

#[allow(clippy::needless_pass_by_value)]
pub fn router(state: WebState) -> Router {
    let session_router: Router = Router::new()
        .merge(auth::router())
        .layer(Extension(state.clone()));

    Router::new()
        .merge(embed::spa_router())
        .merge(session_router)
        .layer(middleware::from_fn(csrf::csrf_middleware))
}

pub use server_state::{OidcContext, OidcSettings, WebState};
