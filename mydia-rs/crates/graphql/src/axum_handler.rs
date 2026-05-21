//! axum mount for the GraphQL surface.
//!
//! Three endpoints, matching the Phoenix shape from
//! `lib/mydia_web/router.ex` and `lib/mydia_web/endpoint.ex`:
//!
//! - `POST /api/graphql` — HTTP query/mutation execution
//! - `GET  /api/graphql/socket` — WebSocket subscriptions
//!   (`graphql-transport-ws` and legacy `graphql-ws` both supported)
//! - `GET  /api/graphql/graphiql` — GraphiQL playground (dev/admin)
//!
//! The per-request context (current user, API key, media token) is
//! added on `GraphQLRequest::data` once the auth middleware lands;
//! today the handler runs anonymous and the schema rejects authed
//! operations through its own checks.

use async_graphql::http::GraphiQLSource;
use async_graphql_axum::{GraphQLRequest, GraphQLResponse, GraphQLSubscription};
use axum::{
    response::{Html, IntoResponse},
    routing::{get, post},
    Extension, Router,
};

use crate::context::GraphqlRequestContext;
use crate::schema::MydiaSchema;

/// Mount the GraphQL surface under `/api/graphql`. Returns an axum
/// `Router` the caller (the application supervisor in U22) merges
/// into the top-level router.
///
/// `GraphQLSubscription` is an axum `Service` rather than a handler
/// fn, so it mounts through `route_service` rather than `get`.
pub fn router(schema: MydiaSchema) -> Router {
    Router::new()
        .route("/api/graphql", post(graphql_handler))
        .route_service(
            "/api/graphql/socket",
            GraphQLSubscription::new(schema.clone()),
        )
        .route("/api/graphql/graphiql", get(graphiql))
        .layer(Extension(schema))
}

async fn graphql_handler(
    Extension(schema): Extension<MydiaSchema>,
    request: GraphQLRequest,
) -> GraphQLResponse {
    // Anonymous context for now; the auth middleware (U6 follow-up,
    // gated on U22's axum supervisor) replaces this with the real
    // CurrentUser once the session cookie / API key / media token
    // extractors run before this handler.
    let request = request
        .into_inner()
        .data(GraphqlRequestContext::anonymous());
    schema.execute(request).await.into()
}

async fn graphiql() -> impl IntoResponse {
    Html(
        GraphiQLSource::build()
            .endpoint("/api/graphql")
            .subscription_endpoint("/api/graphql/socket")
            .title("mydia-rs GraphiQL")
            .finish(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::{build_schema, MydiaSchema};
    use async_graphql::{EmptySubscription, Schema};

    fn schema() -> MydiaSchema {
        // The handler tests don't touch the DB; build a bare schema.
        Schema::build(
            crate::schema::QueryRoot,
            crate::schema::MutationRoot,
            EmptySubscription,
        )
        .finish()
    }

    #[tokio::test]
    async fn router_constructs_without_panic() {
        let _ = router(schema());
    }

    /// Suppress the unused-import warning for `build_schema` when only
    /// the bare constructor is exercised by the bare-schema tests.
    #[allow(dead_code)]
    fn build_schema_is_reachable() -> fn(crate::context::GraphqlAppState) -> MydiaSchema {
        build_schema
    }
}
