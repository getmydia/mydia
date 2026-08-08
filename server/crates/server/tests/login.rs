use axum::body::Body;
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

async fn post_graphql(app: axum::Router, query: &str) -> serde_json::Value {
    let body = serde_json::json!({ "query": query }).to_string();

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/graphql")
                .header("content-type", "application/json")
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();

    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn login_with_correct_credentials_returns_a_token() {
    let (app, _guard) = mydia_server::test_support::app_with_user("alice", "hunter2").await;

    let body = post_graphql(
        app,
        r#"mutation {
             login(input: {
               username: "alice",
               password: "hunter2",
               deviceId: "hardware-abc",
               deviceName: "Living Room TV",
               platform: "android"
             }) { token expiresIn user { username } }
           }"#,
    )
    .await;

    assert!(body["errors"].is_null(), "got errors: {}", body["errors"]);
    assert!(!body["data"]["login"]["token"].as_str().unwrap().is_empty());
    assert_eq!(body["data"]["login"]["user"]["username"], "alice");
}

#[tokio::test]
async fn login_with_a_wrong_password_returns_an_error_and_no_token() {
    let (app, _guard) = mydia_server::test_support::app_with_user("alice", "hunter2").await;

    let body = post_graphql(
        app,
        r#"mutation {
             login(input: {
               username: "alice",
               password: "wrong",
               deviceId: "hardware-abc",
               deviceName: "Living Room TV",
               platform: "android"
             }) { token }
           }"#,
    )
    .await;

    assert!(!body["errors"].is_null(), "a wrong password must error");
    assert!(body["data"]["login"].is_null());
}

#[tokio::test]
async fn logging_in_records_the_device() {
    let (app, _guard) = mydia_server::test_support::app_with_user("alice", "hunter2").await;

    let login = post_graphql(
        app.clone(),
        r#"mutation {
             login(input: {
               username: "alice",
               password: "hunter2",
               deviceId: "hardware-abc",
               deviceName: "Living Room TV",
               platform: "android"
             }) { token }
           }"#,
    )
    .await;

    let token = login["data"]["login"]["token"]
        .as_str()
        .unwrap()
        .to_string();

    let body = mydia_server::test_support::post_graphql_authed(
        app,
        "query { devices { id deviceName } }",
        &token,
    )
    .await;

    assert!(body["errors"].is_null(), "got errors: {}", body["errors"]);
    assert_eq!(body["data"]["devices"][0]["deviceName"], "Living Room TV");
}

#[tokio::test]
async fn the_library_is_empty_but_the_query_succeeds() {
    let (app, _guard) = mydia_server::test_support::app_with_user("alice", "hunter2").await;

    let body = post_graphql(
        app,
        r#"query {
             movies(first: 10) {
               edges { cursor }
               pageInfo { hasNextPage hasPreviousPage }
               totalCount
             }
             tvShows(first: 10) {
               edges { cursor }
               pageInfo { hasNextPage hasPreviousPage }
               totalCount
             }
           }"#,
    )
    .await;

    assert!(body["errors"].is_null(), "got errors: {}", body["errors"]);

    for field in ["movies", "tvShows"] {
        assert_eq!(body["data"][field]["edges"], serde_json::json!([]));
        assert_eq!(body["data"][field]["totalCount"], 0);
        assert_eq!(body["data"][field]["pageInfo"]["hasNextPage"], false);
        assert_eq!(body["data"][field]["pageInfo"]["hasPreviousPage"], false);
    }
}
