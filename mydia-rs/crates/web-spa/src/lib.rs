pub mod auth;
pub mod csrf;
pub mod embed;
pub mod server_state;
pub mod session_config;

use axum::{middleware, Extension, Router};

use crate::server_state::SpaState;

pub fn router(state: SpaState) -> Router {
    let session_layer = session_config::layer(&state.db, false);
    let session_router: Router = Router::new().merge(auth::router()).layer(Extension(state));

    let router = Router::new()
        .merge(embed::spa_router())
        .merge(session_router)
        .layer(middleware::from_fn(csrf::csrf_middleware));

    session_layer.attach(router)
}

#[cfg(test)]
mod tests {
    #[test]
    fn router_constructs() {
        // Placeholder: full router construction needs a DB, tested
        // in integration tests once web-spa is wired into the binary.
    }
}
