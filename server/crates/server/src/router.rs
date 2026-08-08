use async_graphql_axum::{GraphQLRequest, GraphQLResponse};
use axum::extract::State;
use axum::http::HeaderMap;
use axum::routing::{get, post};
use axum::Router;
use mydia_api::context::{ApiContext, BearerToken};
use mydia_api::MydiaSchema;

#[derive(Clone)]
struct AppState {
    schema: MydiaSchema,
}

/// Assembles the HTTP router. Later slices add media byte serving and the
/// admin UI.
pub fn build_router(ctx: ApiContext) -> Router {
    let schema = mydia_api::build_schema(ctx);

    Router::new()
        .route("/health", get(health))
        .route("/api/graphql", post(graphql))
        .with_state(AppState { schema })
}

async fn health() -> &'static str {
    "ok"
}

async fn graphql(
    State(state): State<AppState>,
    headers: HeaderMap,
    req: GraphQLRequest,
) -> GraphQLResponse {
    let mut req = req.into_inner();

    // The bearer token is passed through to resolvers, which decide whether
    // a given field needs it. Rejecting unauthenticated requests here would
    // also reject login itself.
    if let Some(token) = bearer(&headers) {
        req = req.data(BearerToken(token));
    }

    state.schema.execute(req).await.into()
}

fn bearer(headers: &HeaderMap) -> Option<String> {
    headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(|s| s.to_string())
}
