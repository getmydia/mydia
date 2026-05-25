pub mod embed;

use axum::Router;

pub fn router() -> Router {
    Router::new().merge(embed::spa_router())
}
