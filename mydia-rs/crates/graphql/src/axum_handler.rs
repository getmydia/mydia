//! axum mount for the GraphQL surface.
//!
//! Three endpoints, matching the Phoenix shape from
//! `lib/mydia_web/router.ex` and `lib/mydia_web/endpoint.ex`:
//!
//! - `POST /api/graphql` — HTTP query/mutation execution
//! - `GET  /api/graphql/socket` — WebSocket subscriptions
//!   (`graphql-transport-ws` and legacy `graphql-ws` both supported)
//! - `GET  /api/graphql/graphiql` — `GraphiQL` playground (dev/admin)
//!
//! The per-request context (current user, API key, media token) is
//! added on `GraphQLRequest::data` once the auth middleware lands;
//! today the handler runs anonymous and the schema rejects authed
//! operations through its own checks.

use async_graphql::http::GraphiQLSource;
use async_graphql_axum::{GraphQLRequest, GraphQLResponse, GraphQLSubscription};
use axum::{
    response::{Html, IntoResponse},
    routing::get,
    Extension, Router,
};
use mydia_rs_db::types::UuidText;
use mydia_rs_entities::users;
use sea_orm::entity::prelude::*;
use sea_orm::sea_query::{Expr, ExprTrait};
use tower_sessions::Session;
use uuid::Uuid;

use crate::context::{CurrentUser, GraphqlRequestContext};
use crate::schema::MydiaSchema;

const SESSION_KEY_USER_ID: &str = "user_id";

/// Mount the GraphQL surface under `/api/graphql`. Returns an axum
/// `Router` the caller (the application supervisor in U22) merges
/// into the top-level router.
///
/// `GraphQLSubscription` is an axum `Service` rather than a handler
/// fn, so it mounts through `route_service` rather than `get`.
pub fn router(schema: MydiaSchema) -> Router {
    Router::new()
        .route("/api/graphql", get(graphql_handler).post(graphql_handler))
        .route("/graphql", get(graphql_handler).post(graphql_handler))
        .route_service(
            "/api/graphql/socket",
            GraphQLSubscription::new(schema.clone()),
        )
        .route_service("/graphql/ws", GraphQLSubscription::new(schema.clone()))
        .route("/api/graphql/graphiql", get(graphiql))
        .layer(Extension(schema))
}

async fn graphql_handler(
    Extension(schema): Extension<MydiaSchema>,
    session: Session,
    request: GraphQLRequest,
) -> GraphQLResponse {
    let context = if let Some(user_id) = session
        .get::<String>(SESSION_KEY_USER_ID)
        .await
        .ok()
        .flatten()
    {
        if let Ok(Some(user)) = lookup_user_by_id(&schema, &user_id).await {
            GraphqlRequestContext::with_user(user)
        } else {
            GraphqlRequestContext::anonymous()
        }
    } else {
        GraphqlRequestContext::anonymous()
    };

    let request = request.into_inner().data(context);
    schema.execute(request).await.into()
}

async fn lookup_user_by_id(
    schema: &MydiaSchema,
    user_id: &str,
) -> Result<Option<CurrentUser>, String> {
    let state = schema
        .data::<crate::context::GraphqlAppState>()
        .ok_or("GraphqlAppState not in schema data")?;

    let Ok(uuid) = Uuid::parse_str(user_id) else {
        return Ok(None);
    };

    let wrapper = UuidText::from(uuid);
    let backend = state.db.get_database_backend();
    let user = users::Entity::find()
        .filter(Expr::col(users::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .one(&state.db)
        .await
        .map_err(|err| format!("lookup user: {err}"))?;

    Ok(user.map(|u| {
        let role =
            mydia_rs_auth::role::Role::parse(&u.role).unwrap_or(mydia_rs_auth::role::Role::User);
        CurrentUser {
            id: uuid,
            username: u.username.unwrap_or_default(),
            role,
        }
    }))
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
    use crate::schema::{build_schema, MutationRoot, MydiaSchema, QueryRoot};
    use crate::subscriptions::SubscriptionRoot;
    use async_graphql::Schema;

    fn schema() -> MydiaSchema {
        // The handler tests don't touch the DB; build a bare schema
        // using the default merged QueryRoot.
        Schema::build(
            QueryRoot::default(),
            MutationRoot::default(),
            SubscriptionRoot,
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
