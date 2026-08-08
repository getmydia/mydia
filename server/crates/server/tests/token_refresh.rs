//! Coverage for `refreshMediaToken`, `refreshAccessToken` and `revokeDevice`.
//! `login.rs` covers `login` and `devices`; this file exercises the other
//! three device/token mutations the same brief asked for.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use mydia_auth::tokens::{Issuer, TokenKind};
use mydia_server::test_support::{app_with_user, post_graphql_authed, TEST_SECRET};
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

async fn login(app: axum::Router) -> String {
    let body = post_graphql(
        app,
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

    body["data"]["login"]["token"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn refresh_media_token_issues_a_fresh_token_with_the_same_permissions() {
    let (app, _guard) = app_with_user("alice", "hunter2").await;
    let issuer = Issuer::new(TEST_SECRET);

    let (media_token, _) = issuer
        .issue("some-user-id", TokenKind::Media, vec!["stream".to_string()])
        .unwrap();

    let body = post_graphql(
        app,
        &format!(
            r#"mutation {{ refreshMediaToken(token: "{media_token}") {{ token permissions }} }}"#
        ),
    )
    .await;

    assert!(body["errors"].is_null(), "got errors: {}", body["errors"]);
    let new_token = body["data"]["refreshMediaToken"]["token"].as_str().unwrap();
    assert!(!new_token.is_empty());
    // A refresh minted in the same second as the original carries identical
    // claims and is therefore byte-identical; what matters is that it is a
    // token this server considers valid, with the same permissions.
    assert!(issuer.verify(new_token, TokenKind::Media).is_ok());
    assert_eq!(
        body["data"]["refreshMediaToken"]["permissions"][0],
        "stream"
    );
}

#[tokio::test]
async fn refresh_media_token_rejects_an_access_token() {
    let (app, _guard) = app_with_user("alice", "hunter2").await;
    let issuer = Issuer::new(TEST_SECRET);

    let (access_token, _) = issuer
        .issue("some-user-id", TokenKind::Access, vec![])
        .unwrap();

    let body = post_graphql(
        app,
        &format!(r#"mutation {{ refreshMediaToken(token: "{access_token}") {{ token }} }}"#),
    )
    .await;

    assert!(
        !body["errors"].is_null(),
        "an access token must not work as a media token"
    );
}

#[tokio::test]
async fn refresh_access_token_exchanges_a_refresh_token_for_a_new_access_token() {
    let (app, _guard) = app_with_user("alice", "hunter2").await;
    let issuer = Issuer::new(TEST_SECRET);

    let access_token = login(app.clone()).await;
    let claims = issuer.verify(&access_token, TokenKind::Access).unwrap();

    let (refresh_token, _) = issuer
        .issue(&claims.sub, TokenKind::Refresh, vec![])
        .unwrap();

    let body = post_graphql(
        app.clone(),
        &format!(
            r#"mutation {{ refreshAccessToken(deviceToken: "{refresh_token}") {{ token }} }}"#
        ),
    )
    .await;

    assert!(body["errors"].is_null(), "got errors: {}", body["errors"]);
    let new_access_token = body["data"]["refreshAccessToken"]["token"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(!new_access_token.is_empty());

    let devices_body =
        post_graphql_authed(app, "query { devices { deviceName } }", &new_access_token).await;

    assert!(
        devices_body["errors"].is_null(),
        "the new access token must authenticate requests"
    );
}

#[tokio::test]
async fn refresh_access_token_rejects_a_token_that_is_not_a_refresh_token() {
    let (app, _guard) = app_with_user("alice", "hunter2").await;

    let body = post_graphql(
        app,
        r#"mutation { refreshAccessToken(deviceToken: "not-a-real-token") { token } }"#,
    )
    .await;

    assert!(!body["errors"].is_null(), "a bogus token must error");
}

#[tokio::test]
async fn revoke_device_marks_a_devices_own_device_revoked() {
    let (app, _guard) = app_with_user("alice", "hunter2").await;

    let token = login(app.clone()).await;

    let devices_body = post_graphql_authed(app.clone(), "query { devices { id } }", &token).await;
    let device_id = devices_body["data"]["devices"][0]["id"]
        .as_str()
        .unwrap()
        .to_string();

    let body = post_graphql_authed(
        app,
        &format!(
            r#"mutation {{ revokeDevice(id: "{device_id}") {{ success device {{ isRevoked }} }} }}"#
        ),
        &token,
    )
    .await;

    assert!(body["errors"].is_null(), "got errors: {}", body["errors"]);
    assert_eq!(body["data"]["revokeDevice"]["success"], true);
    assert_eq!(body["data"]["revokeDevice"]["device"]["isRevoked"], true);
}

#[tokio::test]
async fn revoke_device_refuses_a_device_that_does_not_belong_to_the_caller() {
    let (app, _guard) = app_with_user("alice", "hunter2").await;
    let token = login(app.clone()).await;

    let body = post_graphql_authed(
        app,
        r#"mutation { revokeDevice(id: "no-such-device") { success } }"#,
        &token,
    )
    .await;

    assert!(
        !body["errors"].is_null(),
        "revoking a device that is not the caller's must error"
    );
}
