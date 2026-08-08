use axum::routing::get;
use axum::Router;

/// Assembles the HTTP router. Later slices add the GraphQL endpoint,
/// media byte serving, and the admin UI.
pub fn build_router() -> Router {
    Router::new().route("/health", get(health))
}

async fn health() -> &'static str {
    "ok"
}
