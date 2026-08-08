//! Helpers for integration tests. Compiled always rather than behind
//! #[cfg(test)] because integration tests link the library as an external
//! crate and cannot see cfg(test) items.

use axum::Router;
use mydia_api::context::ApiContext;
use mydia_auth::tokens::Issuer;
use mydia_db::users::{create, NewUser};

/// The signing secret every test server in this module uses. Exported so a
/// test can mint its own tokens (e.g. a refresh token) with an `Issuer` that
/// verifies against the same server.
pub const TEST_SECRET: &[u8] = b"test-secret-that-is-long-enough-for-hs256";

/// Builds a router backed by a throwaway database holding one user. Hold the
/// returned TempDir for the duration of the test.
pub async fn app_with_user(username: &str, password: &str) -> (Router, tempfile::TempDir) {
    let (db, guard) = mydia_db::pool::connect_temp().await.unwrap();

    create(
        &db,
        NewUser {
            username: username.to_string(),
            email: None,
            display_name: None,
            password_hash: mydia_auth::password::hash(password).unwrap(),
            is_admin: true,
        },
    )
    .await
    .unwrap();

    let ctx = ApiContext {
        db,
        issuer: Issuer::new(TEST_SECRET),
    };

    (crate::router::build_router(ctx), guard)
}

pub async fn post_graphql_authed(app: Router, query: &str, token: &str) -> serde_json::Value {
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;

    let body = serde_json::json!({ "query": query }).to_string();

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/graphql")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();

    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();

    serde_json::from_slice(&bytes).unwrap()
}
